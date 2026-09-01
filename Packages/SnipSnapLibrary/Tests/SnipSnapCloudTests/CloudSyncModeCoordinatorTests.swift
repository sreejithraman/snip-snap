import SnipSnapCore
import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

final class ICloudSyncModeCoordinatorTests: XCTestCase {
    func failFirstSendRetryably(
        coordinator: ICloudSyncModeCoordinator,
        persistence: SwiftDataSyncModePersistence,
        transport: FakeCloudRecordTransport,
        namespace: CloudSyncNamespace,
        failedSnipID: UUID
    ) async throws -> ICloudSyncModeStatus {
        await transport.pauseNextSend()
        let enable = Task { try await coordinator.enableOrRetry() }
        await transport.waitUntilSendPauses()
        let storage = try await persistence.snapshot()
        let transition = try XCTUnwrap(storage.transition)
        let candidate = try await persistence.libraryForTransition(
            storeID: transition.candidateStoreID
        )
        let cloud = try await candidate.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        let failed = try XCTUnwrap(cloud.records.first(where: { $0.snipID == failedSnipID }))
        await transport.failNextSentItem(
            CloudRecordID(
                zone: CloudZoneID(name: failed.identity.zoneName, ownerName: failed.identity.ownerName),
                name: failed.identity.recordName
            ),
            failure: .retryable
        )
        await transport.resumeSend()
        return try await enable.value
    }

    func stripSyncProtocol(from value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                guard entry.key != "syncProtocol" else { return }
                result[entry.key] = stripSyncProtocol(from: entry.value)
            }
        }
        if let array = value as? [Any] {
            return array.map(stripSyncProtocol(from:))
        }
        return value
    }

    func mutateManifest(
        at url: URL,
        mutation: (inout [String: Any]) throws -> Void
    ) throws {
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        try mutation(&manifest)
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: url, options: .atomic)
    }

    func add(_ text: String, to library: any SnipLibrary) async throws {
        _ = try await library.perform(
            .add(
                content: text,
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
    }

    func createList(
        _ name: String,
        systemImage: String,
        in library: any SnipLibrary
    ) async throws -> SnipList {
        let update = try await library.perform(
            .createList(name: name, systemImage: systemImage),
            sortedBy: .chronological
        )
        guard case .listCreated(let list) = update.outcome else {
            throw SnipLibraryError.invalidStore
        }
        return list
    }

    func seed(_ text: String, id: CloudRecordID, server: FakeCloudServer) async throws {
        let writer = FakeCloudRecordTransport(server: server)
        _ = try await writer.send(
            CloudOutboundBatch(
                operations: [
                    .save(.text(id: id, snipID: UUID(), text: text))
                ]
            )
        )
    }

    func cloudRecordID(
        for snipID: UUID,
        persistence: SwiftDataSyncModePersistence,
        namespace: CloudSyncNamespace
    ) async throws -> CloudRecordID {
        let storage = try await persistence.snapshot()
        let transition = try XCTUnwrap(storage.transition)
        let candidate = try await persistence.libraryForTransition(
            storeID: transition.candidateStoreID
        )
        let cloud = try await candidate.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        let record = try XCTUnwrap(cloud.records.first(where: { $0.snipID == snipID }))
        return CloudRecordID(
            zone: CloudZoneID(name: record.identity.zoneName, ownerName: record.identity.ownerName),
            name: record.identity.recordName
        )
    }

    func editRemote(
        recordID: CloudRecordID,
        snipID: UUID,
        text: String,
        server: FakeCloudServer
    ) async throws {
        let remote = try await server.snapshot(
            for: recordID,
            fields: ["schemaVersion", "snipID", "text"]
        )
        let current = try XCTUnwrap(remote)
        let writer = FakeCloudRecordTransport(server: server)
        let sent = try await writer.send(
            CloudOutboundBatch(
                operations: [
                    .save(.text(id: recordID, snipID: snipID, text: text, base: current.shadow))
                ]
            )
        )
        guard sent.items.count == 1, case .saved = sent.items[0] else {
            XCTFail("The remote edit was not accepted.")
            return
        }
    }

    func makeNamespace() -> CloudSyncNamespace {
        CloudSyncNamespace(
            cloudScope: "private",
            accountLineage: "account",
            generation: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            zones: [CloudZoneID(name: "metadata", ownerName: "owner")]
        )
    }

    func textZone(_ namespace: CloudSyncNamespace) -> CloudZoneID {
        namespace.zones.first!
    }

    func testBinding() -> ICloudSyncNamespaceBinding {
        let namespace = makeNamespace()
        return ICloudSyncNamespaceBinding(
            scope: namespace.cloudScope,
            accountLineage: namespace.accountLineage,
            generation: namespace.generation,
            zones: Set(namespace.zones.map {
                ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName)
            })
        )
    }

    func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ICloudSyncModeCoordinatorTests-\(UUID().uuidString)")
    }

    func storeRootCount(in root: URL) throws -> Int {
        let stores = root.appendingPathComponent("stores", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(
            at: stores,
            includingPropertiesForKeys: nil
        ).count
    }
}

actor CloudApplyGate {
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func pause() async throws {
        paused = true
        waiters.forEach { $0.resume() }
        waiters = []
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resume() {
        release?.resume()
        release = nil
        paused = false
    }
}

final class CrashInjector: @unchecked Sendable {
    enum Failure: Error { case injected }

    private let lock = NSLock()
    private let point: SyncModeCrashPoint
    private var didFail = false

    init(point: SyncModeCrashPoint) { self.point = point }

    func hit(_ point: SyncModeCrashPoint) throws {
        lock.lock()
        defer { lock.unlock() }
        guard point == self.point, !didFail else { return }
        didFail = true
        throw Failure.injected
    }
}

final class FailingManifestWriter: @unchecked Sendable {
    enum Failure: Error { case injected }

    private let lock = NSLock()
    var failWrites = false

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        let shouldFail = failWrites
        lock.unlock()
        if shouldFail { throw Failure.injected }
        try data.write(to: url, options: .atomic)
    }
}

actor WriteReservationGate {
    private var reserved = false
    private var reservationWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func hit(_ point: SyncModeWritePoint) async throws {
        guard point == .afterRevisionReserved else { return }
        reserved = true
        reservationWaiters.forEach { $0.resume() }
        reservationWaiters = []
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilReserved() async {
        if reserved { return }
        await withCheckedContinuation { reservationWaiters.append($0) }
    }

    func resume() {
        release?.resume()
        release = nil
    }
}

actor WriteCrashInjector {
    enum Failure: Error { case injected }
    private var didFail = false

    func hit(_ point: SyncModeWritePoint) async throws {
        guard point == .afterRevisionReserved else { return }
        guard !didFail else { return }
        didFail = true
        throw Failure.injected
    }
}

final class ReadFailureInjector: @unchecked Sendable {
    enum Failure: Error { case injected }
    private let lock = NSLock()
    private var value = false

    var shouldFail: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    func check() throws {
        if lock.withLock({ value }) { throw Failure.injected }
    }
}

final class FailNextManifestWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var failNext = false

    func armAtPointer(_ point: SyncModeCrashPoint) {
        guard point == .beforePointerSwap else { return }
        lock.withLock { failNext = true }
    }

    func armAtSendAttempt(_ point: SyncModeCrashPoint) {
        guard point == .beforeSendAttemptManifest else { return }
        lock.withLock { failNext = true }
    }

    func armAtWriteClear(_ point: SyncModeWritePoint) async throws {
        guard point == .beforeReservationCleared else { return }
        lock.withLock { failNext = true }
    }

    func write(_ data: Data, to url: URL) throws {
        let shouldFail = lock.withLock {
            defer { failNext = false }
            return failNext
        }
        if shouldFail { throw FailingManifestWriter.Failure.injected }
        try data.write(to: url, options: .atomic)
    }
}
