import CloudKit
import Foundation
@testable import SnipSnapCloud
import SnipSnapCore
import Synchronization
import XCTest

private let testControlID = CloudRecordID(
    zone: CloudZoneID(name: "control", ownerName: "owner"),
    name: "active-collection"
)

final class CloudKitTransportCallBoundTests: XCTestCase {
    func testAStalledControlFetchEndsInTime() async {
        let stall = CloudKitCallStall()
        addTeardownBlock { stall.release() }
        let log = DatabaseCallLog()
        let transport = makeControlTransport(calls: recordingCalls(log) { _ in
            await stall.enter()
            throw CloudKitCallStall.Released()
        })

        let outcome = await finish(within: .seconds(5)) { try await transport.fetchControl() }
        stall.release()
        assertNetworkFailure(outcome, "fetchControl must stop waiting for a stalled read")
        XCTAssertEqual(
            log.calls,
            Array(repeating: DatabaseCall(name: "record", kind: .small), count: 3),
            "Each retry attempt must read once"
        )
    }

    func testAStalledClipboardManifestReadEndsInTime() async {
        let stall = CloudKitCallStall()
        addTeardownBlock { stall.release() }
        let log = DatabaseCallLog()
        let transport = makeClipboardTransport(calls: recordingCalls(log) { _ in
            await stall.enter()
            throw CloudKitCallStall.Released()
        })

        let outcome = await finish(within: .seconds(5)) { try await transport.fetch() }
        stall.release()
        assertNetworkFailure(outcome, "fetch must stop waiting for a stalled manifest read")
        XCTAssertEqual(log.reads, ["manifest"])
    }

    func testAStalledClipboardPayloadReadEndsInTime() async throws {
        let stall = CloudKitCallStall()
        addTeardownBlock { stall.release() }
        let fixture = try makeClipboardFixture()
        let log = DatabaseCallLog()
        let transport = makeClipboardTransport(calls: recordingCalls(log) { id in
            if id.recordName == fixture.payloadName { await stall.enter() }
            return try fixture.record(id)
        })

        let outcome = await finish(within: .seconds(5)) { try await transport.fetch() }
        stall.release()
        assertNetworkFailure(outcome, "fetch must stop waiting for a stalled payload read")
        XCTAssertEqual(log.reads, ["manifest", fixture.payloadName])
    }

    func testALateClipboardPayloadReadChangesNothing() async throws {
        let stall = CloudKitCallStall()
        addTeardownBlock { stall.release() }
        let fixture = try makeClipboardFixture()
        let log = DatabaseCallLog()
        let lateReadReturned = TaskEndMark()
        let transport = makeClipboardTransport(calls: recordingCalls(log) { id in
            guard id.recordName == fixture.payloadName else { return try fixture.record(id) }
            await stall.enter()
            defer { lateReadReturned.set() }
            return try fixture.record(id)
        })

        let stalled = await finish(within: .seconds(5)) { try await transport.fetch() }
        assertNetworkFailure(stalled, "fetch must stop waiting for a stalled payload read")
        stall.release()
        let returned = await lateReadReturned.wait(within: .seconds(5))
        XCTAssertTrue(returned, "The late read must return once released")
        // Gives a late result time to reach the cache if anything could still deliver it.
        try await Task.sleep(for: .milliseconds(200))
        let refetched = await finish(within: .seconds(5)) { try await transport.fetch() }

        XCTAssertEqual(try refetched?.get().entries, [fixture.entryID: fixture.payload])
        XCTAssertEqual(
            log.reads,
            ["manifest", fixture.payloadName, "manifest", fixture.payloadName],
            "The second fetch must read the payload again, so the late read never reached the cache"
        )
    }

    func testEachDirectCallUsesItsKind() async throws {
        let descriptor = CloudCollectionDescriptor(
            generation: UUID(),
            metadataZone: CloudZoneID(name: "metadata", ownerName: "owner"),
            payloadZone: CloudZoneID(name: "payload", ownerName: "owner")
        )
        let controlLog = DatabaseCallLog()
        let control = makeControlTransport(bound: .standard, calls: recordingCalls(controlLog) { _ in
            try CloudCollectionControlCodec.record(descriptor, id: testControlID, replacing: nil)
        })
        _ = try await control.fetchControl()
        try await control.createZones(descriptor.zones)
        _ = try await control.saveControl(descriptor, replacing: nil)
        try await control.deleteZones(descriptor.zones)

        let fixture = try makeClipboardFixture()
        let clipboardLog = DatabaseCallLog()
        let clipboard = makeClipboardTransport(bound: .standard, calls: recordingCalls(clipboardLog) {
            try fixture.record($0)
        })
        _ = try await clipboard.fetch()
        try await clipboard.save(
            ClipboardCloudSnapshot(entries: [UUID(): Data("new entry".utf8)]),
            cancellation: ClipboardCloudCancellation()
        )
        try await clipboard.deleteAll()

        XCTAssertEqual(controlLog.calls, [
            DatabaseCall(name: "record", kind: .small),
            DatabaseCall(name: "modifyRecordZones", kind: .small),
            DatabaseCall(name: "modifyRecords", kind: .small),
            DatabaseCall(name: "modifyRecordZones", kind: .small),
        ])
        XCTAssertEqual(clipboardLog.calls, [
            DatabaseCall(name: "saveZone", kind: .small),
            DatabaseCall(name: "record", kind: .transfer),
            DatabaseCall(name: "record", kind: .transfer),
            DatabaseCall(name: "modifyRecords", kind: .transfer),
            DatabaseCall(name: "modifyRecords", kind: .transfer),
            DatabaseCall(name: "deleteZone", kind: .small),
        ])
    }

    private func makeClipboardFixture() throws -> ClipboardFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransportCallBound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try ClipboardFixture(writingInto: directory)
    }

    private func assertNetworkFailure<Value>(
        _ outcome: Result<Value, any Error>?,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch outcome {
        case nil:
            XCTFail("\(message): still waiting after the limit", file: file, line: line)
        case .success?:
            XCTFail("\(message): the call succeeded", file: file, line: line)
        case .failure(let error)?:
            XCTAssertTrue(isCloudKitNetworkFailure(error), "\(message): \(error)", file: file, line: line)
        }
    }
}

private func makeControlTransport(
    bound: CloudKitCallBound = .shortForTests,
    calls: CloudKitDatabaseCalls
) -> CloudKitCollectionControlTransport {
    let clock = RetryClock()
    return CloudKitCollectionControlTransport(
        controlID: testControlID,
        bound: bound,
        calls: calls,
        retry: CloudKitOperationRetry(
            now: { clock.now },
            sleep: { clock.advance($0) },
            diagnostics: AppDiagnosticRecorder(record: { _ in })
        )
    )
}

private func makeClipboardTransport(
    bound: CloudKitCallBound = .shortForTests,
    calls: CloudKitDatabaseCalls
) -> CloudKitClipboardTransport {
    CloudKitClipboardTransport(generation: "call-bound-test", bound: bound, calls: calls)
}

/// Returns `operation`'s result, or nil if it is still running after `timeout`.
private func finish<Value: Sendable>(
    within timeout: Duration,
    _ operation: @escaping @Sendable () async throws -> Value
) async -> Result<Value, any Error>? {
    let ended = TaskEndMark()
    let task = Task {
        defer { ended.set() }
        return try await operation()
    }
    guard await ended.wait(within: timeout) else { return nil }
    return await task.result
}

private struct DatabaseCall: Equatable, Sendable {
    let name: String
    let kind: CloudKitCallBound.Kind
}

private final class DatabaseCallLog: Sendable {
    private struct State {
        var calls: [DatabaseCall] = []
        var reads: [String] = []
    }

    private let state = Mutex(State())

    var calls: [DatabaseCall] { state.withLock { $0.calls } }
    /// The record name of each `record` call, in order.
    var reads: [String] { state.withLock { $0.reads } }

    func append(_ name: String, _ kind: CloudKitCallBound.Kind, reading id: CKRecord.ID? = nil) {
        state.withLock { state in
            state.calls.append(DatabaseCall(name: name, kind: kind))
            if let id { state.reads.append(id.recordName) }
        }
    }
}

/// Logs every call into `log`. Reads go to `read`; every write succeeds.
private func recordingCalls(
    _ log: DatabaseCallLog,
    read: @escaping @Sendable (CKRecord.ID) async throws -> CKRecord
) -> CloudKitDatabaseCalls {
    CloudKitDatabaseCalls(
        record: { id, kind in
            log.append("record", kind, reading: id)
            return try await read(id)
        },
        modifyRecords: { saving, deleting, _, _, kind in
            log.append("modifyRecords", kind)
            var results: CloudKitDatabaseCalls.RecordResults = ([:], [:])
            for record in saving { results.saveResults[record.recordID] = .success(record) }
            for id in deleting { results.deleteResults[id] = .success(()) }
            return results
        },
        modifyRecordZones: { saving, deleting, kind in
            log.append("modifyRecordZones", kind)
            var results: CloudKitDatabaseCalls.ZoneResults = ([:], [:])
            for zone in saving { results.saveResults[zone.zoneID] = .success(zone) }
            for id in deleting { results.deleteResults[id] = .success(()) }
            return results
        },
        saveZone: { zone, kind in
            log.append("saveZone", kind)
            return zone
        },
        deleteZone: { id, kind in
            log.append("deleteZone", kind)
            return id
        }
    )
}

/// Clipboard history in files: a manifest that lists one entry, and that entry's payload.
private struct ClipboardFixture: Sendable {
    let entryID = UUID()
    let payload = Data("clipboard entry".utf8)
    let payloadName = "payload-entry"
    private let manifestURL: URL
    private let payloadURL: URL

    init(writingInto directory: URL) throws {
        manifestURL = directory.appendingPathComponent("manifest.json")
        payloadURL = directory.appendingPathComponent("payload")
        let reference = ClipboardCloudPayloadReference(data: payload, recordName: payloadName)
        try JSONEncoder().encode(ManifestFile(entries: [entryID: reference])).write(to: manifestURL)
        try payload.write(to: payloadURL)
    }

    /// Answers a read like CloudKit, with the manifest or the entry's payload as the record's asset.
    func record(_ id: CKRecord.ID) throws -> CKRecord {
        let record: CKRecord
        switch id.recordName {
        case "manifest":
            record = ClipboardCloudRecordCodec.manifestRecord(id: id)
            ClipboardCloudRecordCodec.setPayload(manifestURL, on: record)
        case payloadName:
            record = ClipboardCloudRecordCodec.payloadRecord(id: id)
            ClipboardCloudRecordCodec.setPayload(payloadURL, on: record)
        default:
            throw CKError(.unknownItem)
        }
        return record
    }
}

/// The clipboard transport's manifest file, with no tombstones.
private struct ManifestFile: Encodable {
    let entries: [UUID: ClipboardCloudPayloadReference]
    var tombstones: [UUID: Date] = [:]
}
