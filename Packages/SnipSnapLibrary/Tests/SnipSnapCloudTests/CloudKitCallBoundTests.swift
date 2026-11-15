import CloudKit
import Foundation
@testable import SnipSnapCloud
import SnipSnapCore
import Synchronization
import XCTest

private let stalledAssetID = CloudRecordID(
    zone: CloudZoneID(name: "payload", ownerName: "owner"),
    name: "attachment-payload"
)

final class CloudKitCallBoundTests: XCTestCase {
    func testFetchAssetStopsWaitingForAStalledRead() async throws {
        let stall = CloudKitCallStall()
        addTeardownBlock { stall.release() }
        let transport = makeDownloadTransport(bound: .shortForTests) { _, _ in
            await stall.enter()
            throw CloudKitCallStall.Released()
        }
        let destination = try CloudAssetDestination(validating: makeTemporaryDirectory())
        let ended = TaskEndMark()
        let fetch = Task {
            defer { ended.set() }
            return try await transport.fetchAsset(
                stalledAssetID,
                field: "asset",
                destination: destination
            )
        }

        let stopped = await ended.wait(within: .seconds(5))
        XCTAssertTrue(stopped, "fetchAsset must stop waiting for a stalled read")
        stall.release()
        do {
            _ = try await fetch.value
            XCTFail("A stalled read must fail the fetch")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure, "\(error)")
        }
    }

    func testFetchAssetWritesNothingWhenItsReadReturnsLate() async throws {
        let stall = CloudKitCallStall()
        addTeardownBlock { stall.release() }
        let assetURL = makeTemporaryDirectory().appendingPathComponent("late-asset")
        try Data("late asset bytes".utf8).write(to: assetURL)
        let readerReturned = TaskEndMark()
        let transport = makeDownloadTransport(bound: .shortForTests) { recordIDs, _ in
            await stall.enter()
            defer { readerReturned.set() }
            guard let recordID = recordIDs.first else { return [:] }
            let record = CKRecord(recordType: "AttachmentPayload", recordID: recordID)
            record["asset"] = CKAsset(fileURL: assetURL)
            return [recordID: .success(record)]
        }
        let destinationURL = makeTemporaryDirectory()
        let destination = try CloudAssetDestination(validating: destinationURL)
        let ended = TaskEndMark()
        let fetch = Task {
            defer { ended.set() }
            return try await transport.fetchAsset(
                stalledAssetID,
                field: "asset",
                destination: destination
            )
        }

        let stopped = await ended.wait(within: .seconds(5))
        XCTAssertTrue(stopped, "fetchAsset must stop waiting for a stalled read")
        stall.release()
        let returned = await readerReturned.wait(within: .seconds(5))
        XCTAssertTrue(returned, "The late read must return once released")
        // Gives a late result time to reach any write it could still trigger.
        try await Task.sleep(for: .milliseconds(200))
        do {
            _ = try await fetch.value
            XCTFail("A read that returns after the limit must still fail the fetch")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure, "\(error)")
        }
        let written = try FileManager.default.contentsOfDirectory(atPath: destinationURL.path)
        XCTAssertEqual(written, [], "A late read must not write the asset")
    }

    func testAccountStateStopsWaitingForAStalledStatusCheck() async {
        let stall = CloudKitCallStall()
        addTeardownBlock { stall.release() }
        let source = CloudKitICloudAccountStateSource(
            accountStatus: {
                await stall.enter()
                return .available
            },
            userRecordID: { CKRecord.ID(recordName: "account-a") },
            bound: .shortForTests
        )
        let ended = TaskEndMark()
        let check = Task {
            defer { ended.set() }
            return await source.currentAccountState()
        }

        let stopped = await ended.wait(within: .seconds(5))
        XCTAssertTrue(stopped, "The account check must stop waiting for a stalled status call")
        stall.release()
        let state = await check.value
        XCTAssertEqual(state, .couldNotDetermine)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CallBound-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

extension CloudKitCallBound {
    /// Short enough that a stalled test call ends within a fraction of a second.
    static let shortForTests = CloudKitCallBound(
        idle: .milliseconds(100),
        smallTotal: .milliseconds(200),
        transferTotal: .milliseconds(200),
        backstopMargin: .milliseconds(100)
    )
}

/// A record transport whose reads go to `readRecords`. Asset fetches never start its engine.
func makeDownloadTransport(
    bound: CloudKitCallBound,
    readRecords: @escaping CloudKitRecordTransport.RecordReader
) -> CloudKitRecordTransport {
    CloudKitRecordTransport(
        namespace: CloudSyncNamespace(
            cloudScope: "call-bound-test",
            accountLineage: "account-a",
            generation: UUID(),
            zones: [CloudZoneID(name: "payload", ownerName: "owner")]
        ),
        automaticallyFetchedZones: nil,
        diagnostics: AppDiagnosticRecorder(record: { _ in }),
        bound: bound,
        readRecords: readRecords,
        makeEngine: { _, _, _ in UnusedRecordEngine() }
    )
}

/// Holds each call that enters it until `release()`, like a CloudKit request that never
/// answers. Tests also release it at teardown, so a build without the bound can't hang.
final class CloudKitCallStall: Sendable {
    struct Released: Error {}

    private struct State {
        var entered = 0
        var released = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func enter() async {
        await withCheckedContinuation { continuation in
            let releasedAlready = state.withLock { state in
                state.entered += 1
                if !state.released { state.waiting.append(continuation) }
                return state.released
            }
            if releasedAlready { continuation.resume() }
        }
    }

    func release() {
        let waiting = state.withLock { state in
            state.released = true
            defer { state.waiting = [] }
            return state.waiting
        }
        waiting.forEach { $0.resume() }
    }

    /// Returns whether a call entered the stall within `timeout`.
    func waitUntilEntered(within timeout: Duration) async -> Bool {
        await poll(within: timeout) { state.withLock { $0.entered > 0 } }
    }
}

private final class UnusedRecordEngine: CloudKitRecordEngine {
    func fetchChanges(_ options: CKSyncEngine.FetchChangesOptions) async throws {}
    func sendChanges(_ options: CKSyncEngine.SendChangesOptions) async throws {}
    var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { [] }
    var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] { [] }
    func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange]) {}
    func remove(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange]) {}
    func add(pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange]) {}
    func remove(pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange]) {}
}

/// Lets test files that don't import CloudKit check for the bound's timeout error.
func isCloudKitNetworkFailure(_ error: any Error) -> Bool {
    (error as? CKError)?.code == .networkFailure
}

extension CloudKitCallBoundTests {
    func testReadReturnsAFastValue() async throws {
        let value = try await CloudKitCallBound.shortForTests.read(.small) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testReadRethrowsTheOperationsError() async {
        struct Failure: Error, Equatable {}
        do {
            _ = try await CloudKitCallBound.shortForTests.read(.small) { () async throws -> Int in
                throw Failure()
            }
            XCTFail("The operation's error must reach the caller")
        } catch {
            XCTAssertEqual(error as? Failure, Failure())
        }
    }

    func testReadGivesUpOnAStalledCallAfterItsTotalAndMargin() async {
        let stall = CloudKitCallStall()
        addTeardownBlock { stall.release() }
        let bound = CloudKitCallBound(
            idle: .milliseconds(100),
            smallTotal: .milliseconds(300),
            transferTotal: .seconds(30),
            backstopMargin: .milliseconds(200)
        )
        let started = ContinuousClock.now
        do {
            _ = try await bound.read(.small) { () async throws -> Int in
                await stall.enter()
                return 0
            }
            XCTFail("A stalled read must time out")
        } catch {
            XCTAssertTrue(isCloudKitNetworkFailure(error), "\(error)")
        }
        let elapsed = started.duration(to: ContinuousClock.now)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(500), "Wait for the total plus the margin")
        XCTAssertLessThan(elapsed, .seconds(5), "A small call must not use the transfer total")
    }

    func testConfigurationsCarryTheIdleAndTotalLimits() {
        let small = CloudKitCallBound.standard.configuration(.small)
        XCTAssertEqual(small.timeoutIntervalForRequest, 30)
        XCTAssertEqual(small.timeoutIntervalForResource, 60)
        XCTAssertEqual(small.qualityOfService, .userInitiated)
        let transfer = CloudKitCallBound.standard.configuration(.transfer)
        XCTAssertEqual(transfer.timeoutIntervalForRequest, 30)
        XCTAssertEqual(transfer.timeoutIntervalForResource, 600)
        XCTAssertEqual(transfer.qualityOfService, .userInitiated)
    }
}
