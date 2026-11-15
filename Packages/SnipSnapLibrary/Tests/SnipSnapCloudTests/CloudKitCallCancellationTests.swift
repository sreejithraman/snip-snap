import CloudKit
import Foundation
import SnipSnapCloud
import XCTest

private let cancelledAssetID = CloudRecordID(
    zone: CloudZoneID(name: "payload", ownerName: "owner"),
    name: "attachment-payload"
)

final class CloudKitCallCancellationTests: XCTestCase {
    func testCallerCancellationReachesAStalledRead() async throws {
        let readerStarted = TaskEndMark()
        let readerCancelled = TaskEndMark()
        let longBackstop = CloudKitCallBound(
            idle: .seconds(10),
            smallTotal: .seconds(10),
            transferTotal: .seconds(10),
            backstopMargin: .seconds(1)
        )
        let transport = makeDownloadTransport(bound: longBackstop) { _, _ in
            readerStarted.set()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                readerCancelled.set()
                throw error
            }
            return [:]
        }
        let destination = try CloudAssetDestination(validating: makeTemporaryDirectory())
        let ended = TaskEndMark()
        let fetch = Task {
            defer { ended.set() }
            return try await transport.fetchAsset(
                cancelledAssetID,
                field: "asset",
                destination: destination
            )
        }
        let started = await readerStarted.wait(within: .seconds(5))
        XCTAssertTrue(started, "The fetch must reach its read")

        fetch.cancel()
        let sawCancel = await readerCancelled.wait(within: .seconds(2))
        XCTAssertTrue(sawCancel, "The caller's cancel must reach the stalled read")
        let stopped = await ended.wait(within: .seconds(2))
        XCTAssertTrue(stopped, "A cancelled fetch must end once its read stops")
    }

    func testBackstopCancelsTheAbandonedRead() async throws {
        let readerCancelled = TaskEndMark()
        let transport = makeDownloadTransport(bound: .shortForTests) { _, _ in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                readerCancelled.set()
                throw error
            }
            return [:]
        }
        let destination = try CloudAssetDestination(validating: makeTemporaryDirectory())
        let ended = TaskEndMark()
        let fetch = Task {
            defer { ended.set() }
            return try await transport.fetchAsset(
                cancelledAssetID,
                field: "asset",
                destination: destination
            )
        }

        let stopped = await ended.wait(within: .seconds(5))
        XCTAssertTrue(stopped, "fetchAsset must stop at the backstop")
        let sawCancel = await readerCancelled.wait(within: .seconds(2))
        XCTAssertTrue(sawCancel, "The backstop must cancel the read it abandons")
        // Ends a fetch that is still waiting, so the test never waits for the 30 s reader.
        fetch.cancel()
        do {
            _ = try await fetch.value
            XCTFail("A read that outlasts the backstop must fail the fetch")
        } catch {
            XCTAssertTrue(isCloudKitNetworkFailure(error), "\(error)")
        }
    }

    func testFetchRecordStopsWaitingForAStalledRead() async throws {
        let stall = CloudKitCallStall()
        addTeardownBlock { stall.release() }
        let transport = makeDownloadTransport(bound: .shortForTests) { _, _ in
            await stall.enter()
            throw CloudKitCallStall.Released()
        }
        let ended = TaskEndMark()
        let fetch = Task {
            defer { ended.set() }
            return try await transport.fetchRecord(cancelledAssetID, fields: ["asset"])
        }

        let stopped = await ended.wait(within: .seconds(5))
        XCTAssertTrue(stopped, "fetchRecord must stop waiting for a stalled read")
        stall.release()
        do {
            _ = try await fetch.value
            XCTFail("A stalled read must fail the record fetch")
        } catch {
            XCTAssertEqual(error as? CloudTransportError, .fetchFailed, "\(error)")
        }
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CallCancel-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
