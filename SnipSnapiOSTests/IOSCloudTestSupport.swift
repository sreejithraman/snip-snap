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

enum IOSCachePreflightFailure: Error, AppDiagnosticErrorCodeProviding {
    case pathOutsideRoot

    var appDiagnosticCode: String { "storage.pathOutsideRoot" }
}

actor IOSCloudSyncHandlerProbe: OptionalCloudSyncHandling {
    private var states: [UUID: SyncedAttachmentTransferState]
    private let active: Bool
    private let activeReadFails: Bool
    private let activeReadFailsAfterFirst: Bool
    private let stateReadFails: Bool
    private var activeReadCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var prepareContinuations: [CheckedContinuation<URL, any Error>] = []
    private var prepareStarted = false
    private var prepareCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var syncCalls = 0
    private var prepareCalls = 0

    init(
        states: [UUID: SyncedAttachmentTransferState],
        isActive: Bool = true,
        activeReadFails: Bool = false,
        activeReadFailsAfterFirst: Bool = false,
        stateReadFails: Bool = false
    ) {
        self.states = states
        active = isActive
        self.activeReadFails = activeReadFails
        self.activeReadFailsAfterFirst = activeReadFailsAfterFirst
        self.stateReadFails = stateReadFails
    }

    func refreshAppleAccountNotice() async throws -> AppleAccountNotice? { nil }
    func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {}
    func syncWhenPossible() async { syncCalls += 1 }
    func isCloudSyncActive() async throws -> Bool {
        defer { activeReadCount += 1 }
        if activeReadFails || (activeReadFailsAfterFirst && activeReadCount > 0) {
            throw SnipLibraryError.storeUnavailable
        }
        return active
    }
    func syncCount() -> Int { syncCalls }
    func prepareCount() -> Int { prepareCalls }
    func setState(_ state: SyncedAttachmentTransferState, for id: UUID) { states[id] = state }
    func syncedAttachmentStates() async throws -> [UUID: SyncedAttachmentTransferState] {
        if stateReadFails { throw SnipLibraryError.storeUnavailable }
        return states
    }
    func clearDownloadedFiles() async throws {}

    func prepareSyncedAttachment(_ id: UUID, for use: SyncedAttachmentUse) async throws -> URL {
        prepareCalls += 1
        prepareStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        let ready = prepareCountWaiters.filter { prepareCalls >= $0.0 }
        prepareCountWaiters.removeAll { prepareCalls >= $0.0 }
        ready.forEach { $0.1.resume() }
        return try await withCheckedThrowingContinuation { prepareContinuations.append($0) }
    }

    func waitUntilPrepareStarts() async {
        if prepareStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilPrepareCount(_ count: Int) async {
        if prepareCalls >= count { return }
        await withCheckedContinuation { prepareCountWaiters.append((count, $0)) }
    }

    func finishPrepare(with result: Result<URL, any Error>, at index: Int = 0) {
        guard prepareContinuations.indices.contains(index) else { return }
        let continuation = prepareContinuations.remove(at: index)
        switch result {
        case .success(let url): continuation.resume(returning: url)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

actor IOSCloudSyncSessionProbe: IOSCloudSyncSessionHandling {
    enum Failure: LocalizedError {
        case offline

        var errorDescription: String? { "iCloud is offline." }
    }

    private let result: SnipSnapCloudSyncResult
    private let library: any SnipLibrary
    private let syncError: Failure?
    private var synchronizeCallCount = 0
    private var retryCallCount = 0
    private var scheduleCallCount = 0
    private let pausesCloudWork: Bool
    private var cloudWorkStarted = false
    private var cloudWorkStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var cloudWorkRelease: CheckedContinuation<Void, Never>?
    nonisolated let automaticSyncResults: AsyncStream<SnipSnapCloudSyncResult>

    init(
        result: SnipSnapCloudSyncResult,
        activeLibrary: any SnipLibrary,
        syncError: Failure? = nil,
        pausesCloudWork: Bool = false,
        automaticSyncResults: AsyncStream<SnipSnapCloudSyncResult> = AsyncStream { $0.finish() }
    ) {
        self.result = result
        library = activeLibrary
        self.syncError = syncError
        self.pausesCloudWork = pausesCloudWork
        self.automaticSyncResults = automaticSyncResults
    }

    func synchronize() async throws -> SnipSnapCloudSyncResult {
        synchronizeCallCount += 1
        await pauseCloudWorkIfNeeded()
        if let syncError { throw syncError }
        return result
    }

    func retrySynchronization() async throws -> SnipSnapCloudSyncResult {
        retryCallCount += 1
        await pauseCloudWorkIfNeeded()
        if let syncError { throw syncError }
        return result
    }

    func scheduleAutomaticSync() async {
        scheduleCallCount += 1
        await pauseCloudWorkIfNeeded()
    }

    func iosActiveLibrary()
        -> (library: any SnipLibrary, recoveryScope: SnipRecoveryScope?)
    {
        (library, nil)
    }

    func syncCount() -> Int { synchronizeCallCount }
    func retryCount() -> Int { retryCallCount }
    func scheduleCount() -> Int { scheduleCallCount }

    func waitUntilCloudWorkStarts() async {
        if cloudWorkStarted { return }
        await withCheckedContinuation { cloudWorkStartWaiters.append($0) }
    }

    func resumeCloudWork() {
        cloudWorkRelease?.resume()
        cloudWorkRelease = nil
    }

    private func pauseCloudWorkIfNeeded() async {
        guard pausesCloudWork else { return }
        cloudWorkStarted = true
        cloudWorkStartWaiters.forEach { $0.resume() }
        cloudWorkStartWaiters.removeAll()
        await withCheckedContinuation { cloudWorkRelease = $0 }
    }
}

actor MutableIOSCloudSyncHandler: OptionalCloudSyncHandling {
    private var active: Bool
    private var states: [UUID: SyncedAttachmentTransferState]

    init(active: Bool, states: [UUID: SyncedAttachmentTransferState]) {
        self.active = active
        self.states = states
    }

    func set(active: Bool, states: [UUID: SyncedAttachmentTransferState]) {
        self.active = active
        self.states = states
    }

    func refreshAppleAccountNotice() async throws -> AppleAccountNotice? { nil }
    func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {}
    func syncWhenPossible() async {}
    func isCloudSyncActive() async throws -> Bool { active }
    func syncedAttachmentStates() async throws -> [UUID: SyncedAttachmentTransferState] {
        states
    }
    func clearDownloadedFiles() async throws {}
    func prepareSyncedAttachment(
        _ id: UUID,
        for use: SyncedAttachmentUse
    ) async throws -> URL {
        throw SnipLibraryError.attachmentCopyFailed
    }
}

actor IOSCopyShareActionHandlerProbe: OptionalCloudSyncHandling {
    struct PrepareCall: Equatable {
        let id: UUID
        let use: SyncedAttachmentUse
    }

    private let states: [UUID: SyncedAttachmentTransferState]
    private var results: [Result<URL, any Error>]
    private var calls: [PrepareCall] = []

    init(
        states: [UUID: SyncedAttachmentTransferState],
        results: [Result<URL, any Error>]
    ) {
        self.states = states
        self.results = results
    }

    func refreshAppleAccountNotice() async throws -> AppleAccountNotice? { nil }
    func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {}
    func syncWhenPossible() async {}
    func isCloudSyncActive() async throws -> Bool { true }
    func syncedAttachmentStates() async throws -> [UUID: SyncedAttachmentTransferState] { states }
    func clearDownloadedFiles() async throws {}

    func prepareSyncedAttachment(_ id: UUID, for use: SyncedAttachmentUse) async throws -> URL {
        calls.append(PrepareCall(id: id, use: use))
        guard !results.isEmpty else { throw SnipLibraryError.attachmentCopyFailed }
        return try results.removeFirst().get()
    }

    func prepareCalls() -> [PrepareCall] { calls }
}
