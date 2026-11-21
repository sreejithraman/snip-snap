import SnipSnapCore
import SnipSnapPersistence
@testable import SnipSnapCloud
import Synchronization
import XCTest

final class ICloudSyncModeCoordinatorTests: XCTestCase {
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
                    .save(try CloudFullRecordCodec.snipDraft(Snip(content: text, origin: .quickEntry), in: id.zone))
                ]
            )
        )
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

final class FailingManifestWriter: Sendable {
    enum Failure: Error { case injected }

    private let failureEnabled = Mutex<Bool>(false)

    var failWrites: Bool {
        get { failureEnabled.withLock { $0 } }
        set { failureEnabled.withLock { $0 = newValue } }
    }

    func write(_ data: Data, to url: URL) throws {
        if failWrites { throw Failure.injected }
        try data.write(to: url, options: .atomic)
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

    func write(_ data: Data, to url: URL) throws {
        let shouldFail = lock.withLock {
            defer { failNext = false }
            return failNext
        }
        if shouldFail { throw FailingManifestWriter.Failure.injected }
        try data.write(to: url, options: .atomic)
    }
}

extension ICloudSyncModeCoordinator {
    /// Test setup for cases that need a settled server record as their merge base.
    func enableAndPublish() async throws -> ICloudSyncModeStatus {
        let status = try await enableOrRetry()
        if status.state == .on { _ = try await syncActive() }
        return status
    }
}
