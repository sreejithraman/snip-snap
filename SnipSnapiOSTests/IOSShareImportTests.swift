import Observation
import ImageIO
import SnipSnapCore
import SnipSnapCloud
import SnipSnapPersistence
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import SnipSnapiOS

@MainActor
final class IOSShareImportTests: IOSModelTestCase {
    func testSavingASnipSchedulesCloudSync() async {
        let handler = IOSCloudSyncHandlerProbe(states: [:])
        let model = IOSAppModel(library: ModelTestLibrary(), cloudSyncHandler: handler)

        let created = await model.createSnip(content: "Saved", in: SnipList.inboxID)
        XCTAssertTrue(created)
        for _ in 0..<20 {
            if await handler.syncCount() > 0 { break }
            await Task.yield()
        }

        let syncCount = await handler.syncCount()
        XCTAssertEqual(syncCount, 1)
    }

    func testRootReinitializationKeepsForegroundImportOnRetainedGraph() async throws {
        let library = ModelTestLibrary()
        let firstProbe = ImportCallProbe()
        let state = RootReinitHarnessState()
        let session = IOSAppSession(
            library: library,
            shareImportOperation: { await firstProbe.run() }
        )
        let host = UIHostingController(
            rootView: RootReinitHarness(
                state: state,
                session: session
            )
        )
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let didLaunch = await waitForCalls(1, from: firstProbe)
        XCTAssertTrue(didLaunch)
        state.generation = 1
        try? await Task.sleep(for: .milliseconds(30))
        state.phase = .background
        try? await Task.sleep(for: .milliseconds(30))
        state.phase = .active

        let didImportOnForeground = await waitForCalls(2, from: firstProbe)
        XCTAssertTrue(didImportOnForeground)
    }

    func testLaunchAndForegroundQueueOneTrailingImportThenALaterForegroundRunsAgain() async {
        let snip = Snip(
            requestID: UUID(),
            content: "From Share",
            origin: .share,
            listID: SnipList.inboxID
        )
        let library = ModelTestLibrary(snips: [snip])
        let model = makeModel(library: library)
        let probe = PendingImportProbe()
        let coordinator = IOSShareImportCoordinator(
            model: model,
            importOperation: { await probe.run() }
        )

        let launch = Task { await coordinator.importPendingAndReload() }
        await probe.waitUntilFirstImportStarts()
        let overlappingForeground = Task { await coordinator.importPendingAndReload() }
        await Task.yield()
        await probe.finishFirstImport()
        await launch.value
        await overlappingForeground.value

        let overlappingCallCount = await probe.callCount()
        XCTAssertEqual(overlappingCallCount, 2)
        XCTAssertEqual(model.snips.map(\.id), [snip.id])

        await coordinator.importPendingAndReload()
        let foregroundCallCount = await probe.callCount()
        XCTAssertEqual(foregroundCallCount, 3)
    }

    func testTriggerDuringImportTailQueuesOneTrailingPassForANewerRequest() async {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        let probe = TrailingShareImportProbe(library: library)
        let firstRequestID = UUID()
        let secondRequestID = UUID()
        await probe.publish(content: "First request", requestID: firstRequestID)
        let coordinator = IOSShareImportCoordinator(
            model: model,
            importOperation: { await probe.importPending() },
            syncOperation: { await probe.sync() }
        )

        let firstTrigger = Task { await coordinator.importPendingAndReload() }
        await probe.waitUntilFirstPassScanned()
        await probe.publish(content: "Second request", requestID: secondRequestID)
        let overlappingTrigger = Task { await coordinator.importPendingAndReload() }
        await Task.yield()
        await probe.releaseFirstPass()
        await firstTrigger.value
        await overlappingTrigger.value

        let snapshot = await library.snapshot(sortedBy: .chronological)
        XCTAssertEqual(snapshot.snips.count, 2)
        XCTAssertEqual(Set(snapshot.snips.map(\.requestID)), [firstRequestID, secondRequestID])
        let importPasses = await probe.importCallCount()
        XCTAssertEqual(importPasses, 2)
        let syncPasses = await probe.syncCallCount()
        XCTAssertEqual(syncPasses, 2)
    }

    func testEmptyImportPassesDoNotRequestRedundantSync() async {
        let model = IOSAppModel(library: ModelTestLibrary())
        let probe = ImportThenSyncProbe()
        let coordinator = IOSShareImportCoordinator(
            model: model,
            importOperation: { await probe.importPending() },
            syncOperation: { try await probe.syncActive() }
        )

        await coordinator.importPendingAndReload()
        await coordinator.importPendingAndReload()

        let events = await probe.events()
        XCTAssertEqual(events, [.importPending, .importPending])
    }

    func testForegroundWithoutPendingShareSchedulesAutomaticSyncAndShowsNoShareAlert() async {
        let library = ModelTestLibrary()
        let cloudSession = IOSCloudSyncSessionProbe(
            result: .noChange,
            activeLibrary: library,
            syncError: .offline
        )
        let session = IOSAppSession(
            library: library,
            cloudSyncSession: cloudSession,
            shareImportOperation: { ShareImportSummary(imported: 0, failed: 0) }
        )

        await session.foreground()

        let syncCount = await cloudSession.syncCount()
        let scheduleCount = await cloudSession.scheduleCount()
        XCTAssertEqual(syncCount, 0)
        XCTAssertEqual(scheduleCount, 1)
        XCTAssertNil(session.model.errorMessage)
    }

    func testLaunchShowsCachedLibraryBeforeAutomaticCloudWorkFinishes() async {
        let cached = Snip(content: "Cached", origin: .quickEntry)
        let library = ModelTestLibrary(snips: [cached])
        let cloudSession = IOSCloudSyncSessionProbe(
            result: .syncScheduled,
            activeLibrary: library,
            pausesCloudWork: true
        )
        let session = IOSAppSession(library: library, cloudSyncSession: cloudSession)

        let launch = Task { await session.launch() }
        await cloudSession.waitUntilCloudWorkStarts()

        XCTAssertEqual(session.model.snips.map(\.id), [cached.id])

        await cloudSession.resumeCloudWork()
        await launch.value
        let syncCount = await cloudSession.syncCount()
        let scheduleCount = await cloudSession.scheduleCount()
        XCTAssertEqual(syncCount, 0)
        XCTAssertEqual(scheduleCount, 1)
    }

    func testTrailingEmptyPassDoesNotRepeatAShareSync() async {
        let model = IOSAppModel(library: ModelTestLibrary())
        let imports = QueuedImportSummaryProbe(
            summaries: [
                ShareImportSummary(imported: 1, failed: 0),
                ShareImportSummary(imported: 0, failed: 0)
            ]
        )
        let sync = SequencedSyncProbe(failures: [true])
        let coordinator = IOSShareImportCoordinator(
            model: model,
            importOperation: { await imports.run() },
            syncOperation: { try await sync.run() }
        )

        let first = Task { await coordinator.importPendingAndReload() }
        await imports.waitUntilFirstImportStarts()
        let overlapping = Task { await coordinator.importPendingAndReload() }
        await Task.yield()
        await imports.finishFirstImport()
        await first.value
        await overlapping.value

        let syncCount = await sync.callCount()
        XCTAssertEqual(syncCount, 1)
        XCTAssertNil(model.errorMessage)
    }

    func testRecoveredTrailingImportDoesNotReportAnEarlierFailure() async {
        let model = IOSAppModel(library: ModelTestLibrary())
        let imports = QueuedImportSummaryProbe(summaries: [
            ShareImportSummary(imported: 0, failed: 1),
            ShareImportSummary(imported: 1, failed: 0)
        ])
        let coordinator = IOSShareImportCoordinator(
            model: model, importOperation: { await imports.run() }
        )
        let first = Task { await coordinator.importPendingAndReload() }
        await imports.waitUntilFirstImportStarts()
        let overlapping = Task { await coordinator.importPendingAndReload() }
        await Task.yield()
        await imports.finishFirstImport()
        await first.value
        await overlapping.value

        let passes = await imports.callCount()
        XCTAssertEqual(passes, 2)
        XCTAssertNil(model.errorMessage)
    }

    func testNoPendingShareDoesNotResolveActiveCloudLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NoPendingShare-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ModelTestLibrary()
        let cloudSession = ActiveLibraryFailureProbe()
        let session = IOSAppSession(
            library: library,
            shareImports: ShareImportStore(sharedRootURL: root),
            cloudSyncSession: cloudSession
        )

        await session.foreground()

        let activeLibraryCalls = await cloudSession.activeLibraryCallCount()
        XCTAssertEqual(activeLibraryCalls, 0)
        XCTAssertNil(session.model.errorMessage)
    }

    func testPendingShareLibraryFailureKeepsRequestAndRecordsItsCause() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let imports = ShareImportStore(sharedRootURL: root)
        _ = try await imports.save(ShareImportRequest(
            content: "Private shared text", destinationListID: SnipList.inboxID))
        let diagnostics = IOSDiagnosticRecorderProbe()
        let session = IOSAppSession(
            library: ModelTestLibrary(), shareImports: imports,
            cloudSyncSession: ActiveLibraryFailureProbe(error: SnipLibraryError.storeUnavailable),
            diagnostics: diagnostics.recorder
        )

        await session.foreground()

        let pending = await imports.pendingImportCount()
        XCTAssertEqual(pending, 1)
        XCTAssertNotNil(session.model.errorMessage)
        let failure = diagnostics.events.first { $0.operation == "share.import_library" }
        XCTAssertEqual(failure?.errorCode, "library.storeUnavailable")
        XCTAssertEqual(failure?.visibility, .background)
        XCTAssertFalse(diagnostics.events.map(\.line).joined().contains("Private"))
    }

    func testImportFailureReportsRetryWithoutRedundantSync() async {
        let model = IOSAppModel(library: ModelTestLibrary())
        let syncProbe = SyncCallProbe(error: ProbeError.offline)
        let coordinator = IOSShareImportCoordinator(
            model: model,
            importOperation: { ShareImportSummary(imported: 0, failed: 1) },
            syncOperation: { try await syncProbe.run() }
        )

        await coordinator.importPendingAndReload()

        let syncCalls = await syncProbe.callCount()
        XCTAssertEqual(syncCalls, 0)
        XCTAssertEqual(
            model.errorMessage,
            "Some shared items couldn’t be added. Snip Snap will try again when you reopen the app."
        )
    }

    func testAcceptedImportStillSyncsWhenInboxCleanupFails() async {
        let model = IOSAppModel(library: ModelTestLibrary())
        let imports = QueuedImportSummaryProbe(
            summaries: [
                ShareImportSummary(imported: 1, failed: 0, cleanupFailures: 1),
                ShareImportSummary(imported: 0, failed: 0)
            ],
            blocksFirstImport: false
        )
        let syncProbe = SyncCallProbe()
        let coordinator = IOSShareImportCoordinator(
            model: model,
            importOperation: { await imports.run() },
            syncOperation: { try await syncProbe.run() }
        )

        await coordinator.importPendingAndReload()
        await coordinator.importPendingAndReload()

        let syncCalls = await syncProbe.callCount()
        XCTAssertEqual(syncCalls, 1)
        XCTAssertNil(model.errorMessage)
    }

    func testSyncFailureDoesNotTurnALocalImportIntoAFailedSave() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        let requestID = UUID()
        let coordinator = IOSShareImportCoordinator(
            model: model,
            importOperation: {
                _ = try? await library.perform(
                    .add(
                        content: "Saved before sync",
                        origin: .share,
                        source: nil,
                        listID: SnipList.inboxID,
                        attachmentURLs: [],
                        requestID: requestID,
                        now: Date(timeIntervalSince1970: 50)
                    ),
                    sortedBy: .chronological
                )
                return ShareImportSummary(imported: 1, failed: 0)
            },
            syncOperation: { throw ProbeError.offline }
        )

        await coordinator.importPendingAndReload()

        XCTAssertEqual(model.snips.map(\.requestID), [requestID])
        let acceptedLocalSnapshot = await library.snapshot(sortedBy: .chronological)
        XCTAssertEqual(acceptedLocalSnapshot.snips.map(\.requestID), [requestID])
        XCTAssertNil(model.errorMessage)
    }

    private func waitForCalls(_ expected: Int, from probe: ImportCallProbe) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while await probe.callCount() < expected, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await probe.callCount() >= expected
    }
}

@MainActor
private final class RootReinitHarnessState: ObservableObject {
    @Published var generation = 0
    @Published var phase: ScenePhase = .active
}

private struct RootReinitHarness: View {
    @ObservedObject var state: RootReinitHarnessState
    let session: IOSAppSession

    var body: some View {
        IOSAppRootView(session: session)
            .environment(\.scenePhase, state.phase)
    }
}

private actor PendingImportProbe {
    private var calls = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstImportContinuation: CheckedContinuation<Void, Never>?

    func run() async -> ShareImportSummary {
        calls += 1
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if calls == 1 {
            await withCheckedContinuation { continuation in
                firstImportContinuation = continuation
            }
        }
        return ShareImportSummary(imported: 0, failed: 0)
    }

    func waitUntilFirstImportStarts() async {
        if calls > 0 { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finishFirstImport() {
        firstImportContinuation?.resume()
        firstImportContinuation = nil
    }

    func callCount() -> Int { calls }
}

private actor QueuedImportSummaryProbe {
    private var summaries: [ShareImportSummary]
    private let blocksFirstImport: Bool
    private var firstImportContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var calls = 0

    init(summaries: [ShareImportSummary], blocksFirstImport: Bool = true) {
        self.summaries = summaries
        self.blocksFirstImport = blocksFirstImport
    }

    func run() async -> ShareImportSummary {
        calls += 1
        if calls == 1, blocksFirstImport {
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { firstImportContinuation = $0 }
        }
        return summaries.isEmpty
            ? ShareImportSummary(imported: 0, failed: 0)
            : summaries.removeFirst()
    }

    func waitUntilFirstImportStarts() async {
        if calls > 0 { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finishFirstImport() {
        firstImportContinuation?.resume()
        firstImportContinuation = nil
    }

    func callCount() -> Int { calls }
}

private actor ImportCallProbe {
    private var calls = 0

    func run() -> ShareImportSummary {
        calls += 1
        return ShareImportSummary(imported: 0, failed: 0)
    }

    func callCount() -> Int { calls }
}

private enum ImportThenSyncEvent: Equatable {
    case importPending
    case syncActive
}

private actor ImportThenSyncProbe {
    private var recorded: [ImportThenSyncEvent] = []

    func importPending() -> ShareImportSummary {
        recorded.append(.importPending)
        return ShareImportSummary(imported: 0, failed: 0)
    }

    func syncActive() throws {
        recorded.append(.syncActive)
    }

    func events() -> [ImportThenSyncEvent] { recorded }
}

private actor TrailingShareImportProbe {
    private struct PendingRequest: Sendable {
        let content: String
        let requestID: UUID
    }

    private let library: ModelTestLibrary
    private var pending: [PendingRequest] = []
    private var importCalls = 0
    private var syncCalls = 0
    private var didFirstPassScan = false
    private var firstPassWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstPassRelease: CheckedContinuation<Void, Never>?

    init(library: ModelTestLibrary) {
        self.library = library
    }

    func publish(content: String, requestID: UUID) {
        pending.append(PendingRequest(content: content, requestID: requestID))
    }

    func importPending() async -> ShareImportSummary {
        importCalls += 1
        let scanned = pending
        pending.removeAll()
        for request in scanned {
            _ = try? await library.perform(
                .add(
                    content: request.content,
                    origin: .share,
                    source: nil,
                    listID: SnipList.inboxID,
                    attachmentURLs: [],
                    requestID: request.requestID,
                    now: Date(timeIntervalSince1970: TimeInterval(importCalls))
                ),
                sortedBy: .chronological
            )
        }
        guard importCalls == 1 else {
            return ShareImportSummary(imported: scanned.count, failed: 0)
        }
        didFirstPassScan = true
        firstPassWaiters.forEach { $0.resume() }
        firstPassWaiters.removeAll()
        await withCheckedContinuation { firstPassRelease = $0 }
        return ShareImportSummary(imported: scanned.count, failed: 0)
    }

    func waitUntilFirstPassScanned() async {
        if didFirstPassScan { return }
        await withCheckedContinuation { firstPassWaiters.append($0) }
    }

    func releaseFirstPass() {
        firstPassRelease?.resume()
        firstPassRelease = nil
    }

    func sync() {
        syncCalls += 1
    }

    func importCallCount() -> Int { importCalls }

    func syncCallCount() -> Int { syncCalls }
}

private enum ProbeError: Error {
    case offline
}

private actor SyncCallProbe {
    private var calls = 0
    private let error: (any Error)?

    init(error: (any Error)? = nil) {
        self.error = error
    }

    func run() throws {
        calls += 1
        if let error { throw error }
    }

    func callCount() -> Int { calls }
}

private actor SequencedSyncProbe {
    private var failures: [Bool]
    private var calls = 0

    init(failures: [Bool]) {
        self.failures = failures
    }

    func run() throws {
        calls += 1
        if !failures.isEmpty, failures.removeFirst() {
            throw ProbeError.offline
        }
    }

    func callCount() -> Int { calls }
}

private actor ActiveLibraryFailureProbe: IOSCloudSyncSessionHandling {
    private var activeLibraryCalls = 0
    private let error: any Error

    init(error: any Error = ProbeError.offline) { self.error = error }

    func synchronize() async throws -> SnipSnapCloudSyncResult { .noChange }

    func iosActiveLibrary() async throws
        -> (library: any SnipLibrary, recoveryScope: SnipRecoveryScope?)
    {
        activeLibraryCalls += 1
        throw error
    }

    func activeLibraryCallCount() -> Int { activeLibraryCalls }
}
