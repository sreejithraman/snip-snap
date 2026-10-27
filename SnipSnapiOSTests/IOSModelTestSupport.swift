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
class IOSModelTestCase: XCTestCase {
    func makeModel(library: any SnipLibrary) -> IOSAppModel {
        let actions = DirectSnipLibraryUserActions(library: library)
        return IOSAppModel(library: library, userActions: actions)
    }

    func makeImportModel(library: any SnipLibrary) -> IOSAppModel {
        let assembly = SnipLibraryAssembly(
            library: library,
            activeCloudNamespace: nil
        )
        return IOSAppModel(
            library: assembly.library,
            userActions: assembly.userActions,
            userActionsFactory: assembly.userActionsFactory
        )
    }

    func makeFeedback() -> IOSHapticFeedback {
        let suite = "copy-check-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let feedback = IOSHapticFeedback(defaults: defaults, player: RecordingHapticPlayer())
        feedback.isActive = true
        return feedback
    }
}

@MainActor
final class RecordingHapticPlayer: IOSHapticPlaying {
    var played: [IOSHapticFeedback.Meaning] = []
    func play(_ meaning: IOSHapticFeedback.Meaning) { played.append(meaning) }
}

final class IOSDiagnosticRecorderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [AppDiagnosticEvent] = []

    var recorder: AppDiagnosticRecorder {
        AppDiagnosticRecorder { [self] event in
            lock.withLock { storedEvents.append(event) }
        }
    }

    var events: [AppDiagnosticEvent] {
        lock.withLock { storedEvents }
    }
}

actor ModelTestLibrary: SnipLibrary {
    private var snips: [Snip]
    private var lists: [SnipList] = [.inbox]
    private let attachmentURLs: [UUID: URL]
    private(set) var lastAddedAttachmentURLs: [URL] = []
    private(set) var lastAttachmentEdit: (snipID: UUID, content: String, edits: [SnipAttachmentEdit])?
    private var attachmentPruneCalls = 0
    private var recovery: SnipRecoverySnapshot
    private var resolvedChoices: [SnipRecoveryChoice] = []
    private var attachmentRetentionCalls: [Set<UUID>] = []
    private let commandDelay: Duration?
    private let failsDeletion: Bool
    private let failsListDeletion: Bool
    private let rejectsCancelledCommands: Bool
    private var suspendsFirstCommand: Bool
    private var suspendsNextSnapshot = false
    private var snapshotStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var snapshotContinuation: CheckedContinuation<Void, Never>?
    private var firstCommandStarted = false
    private var firstCommandStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCommandContinuation: CheckedContinuation<Void, Never>?
    private var recoveryStarted = false
    private var suspendsNextRecovery = false
    private var recoveryStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var recoveryContinuation: CheckedContinuation<Void, Never>?
    private var activeCommandCount = 0
    private var maximumActiveCommandCount = 0
    private var lastMergedIDs: Set<UUID>?

    init(
        snips: [Snip] = [],
        lists: [SnipList] = [.inbox],
        recovery: SnipRecoverySnapshot = .empty,
        attachmentURLs: [UUID: URL] = [:],
        commandDelay: Duration? = nil,
        suspendsFirstCommand: Bool = false,
        failsDeletion: Bool = false,
        failsListDeletion: Bool = false,
        rejectsCancelledCommands: Bool = false
    ) {
        self.snips = snips
        self.lists = lists
        self.recovery = recovery
        self.attachmentURLs = attachmentURLs
        self.commandDelay = commandDelay
        self.suspendsFirstCommand = suspendsFirstCommand
        self.failsDeletion = failsDeletion
        self.failsListDeletion = failsListDeletion
        self.rejectsCancelledCommands = rejectsCancelledCommands
    }

    func addedAttachmentURLs() -> [URL] {
        lastAddedAttachmentURLs
    }

    func pruneCalls() -> Int {
        attachmentPruneCalls
    }

    func replaceText(_ text: String, for id: UUID) {
        guard let index = snips.firstIndex(where: { $0.id == id }) else { return }
        snips[index].content = text
    }

    func replaceAttachments(_ attachments: [SnipAttachment], on snipID: UUID) {
        guard let index = snips.firstIndex(where: { $0.id == snipID }) else { return }
        snips[index].attachments = attachments
    }

    func resolutionChoices() -> [SnipRecoveryChoice] {
        resolvedChoices
    }

    func recoverySnapshot(in scope: SnipRecoveryScope) async -> SnipRecoverySnapshot {
        _ = scope
        if suspendsNextRecovery {
            suspendsNextRecovery = false
            recoveryStartWaiters.forEach { $0.resume() }
            recoveryStartWaiters.removeAll()
            await withCheckedContinuation { recoveryContinuation = $0 }
        }
        return recovery
    }

    func suspendNextRecovery() {
        suspendsNextRecovery = true
    }

    func waitUntilRecoveryStarts() async {
        if recoveryContinuation != nil { return }
        await withCheckedContinuation { recoveryStartWaiters.append($0) }
    }

    func resumeRecovery() {
        recoveryContinuation?.resume()
        recoveryContinuation = nil
    }

    func resolveRecovery(
        _ id: UUID,
        in scope: SnipRecoveryScope,
        choice: SnipRecoveryChoice
    ) async throws -> SnipLibrarySnapshot {
        recoveryStarted = true
        activeCommandCount += 1
        maximumActiveCommandCount = max(maximumActiveCommandCount, activeCommandCount)
        defer { activeCommandCount -= 1 }
        _ = scope
        guard recovery.pendingSnips.contains(where: { $0.id == id })
            || recovery.pendingLists.contains(where: { $0.id == id })
        else { throw SnipLibraryError.recoveryNotFound }
        resolvedChoices.append(choice)
        recovery = .empty
        return makeSnapshot(sortMode: .chronological)
    }

    func retentionCalls() -> [Set<UUID>] {
        attachmentRetentionCalls
    }

    func waitUntilFirstCommandStarts() async {
        if firstCommandStarted { return }
        await withCheckedContinuation { firstCommandStartWaiters.append($0) }
    }

    func suspendNextCommand() {
        firstCommandStarted = false
        suspendsFirstCommand = true
    }

    func resumeFirstCommand() {
        firstCommandContinuation?.resume()
        firstCommandContinuation = nil
    }

    func didRecoveryStart() -> Bool {
        recoveryStarted
    }

    func suspendNextSnapshot() {
        suspendsNextSnapshot = true
    }

    func waitUntilSnapshotStarts() async {
        if snapshotContinuation != nil { return }
        await withCheckedContinuation { snapshotStartWaiters.append($0) }
    }

    func resumeSnapshot() {
        snapshotContinuation?.resume()
        snapshotContinuation = nil
    }

    func snapshot(sortedBy sortMode: SnipSortMode) async -> SnipLibrarySnapshot {
        if suspendsNextSnapshot {
            suspendsNextSnapshot = false
            snapshotStartWaiters.forEach { $0.resume() }
            snapshotStartWaiters.removeAll()
            await withCheckedContinuation { snapshotContinuation = $0 }
        }
        return makeSnapshot(sortMode: sortMode)
    }

    func checkedSnapshot(sortedBy sortMode: SnipSortMode) -> SnipLibrarySnapshot {
        makeSnapshot(sortMode: sortMode)
    }

    func perform(
        _ command: SnipLibraryCommand,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SnipLibraryUpdate {
        activeCommandCount += 1
        maximumActiveCommandCount = max(maximumActiveCommandCount, activeCommandCount)
        defer { activeCommandCount -= 1 }
        if suspendsFirstCommand {
            suspendsFirstCommand = false
            firstCommandStarted = true
            firstCommandStartWaiters.forEach { $0.resume() }
            firstCommandStartWaiters.removeAll()
            await withCheckedContinuation { firstCommandContinuation = $0 }
        }
        if let commandDelay { try? await Task.sleep(for: commandDelay) }
        if rejectsCancelledCommands { try Task.checkCancellation() }
        let outcome = try apply(command)
        return SnipLibraryUpdate(snapshot: makeSnapshot(sortMode: sortMode), outcome: outcome)
    }

    func maximumConcurrentOperations() -> Int {
        maximumActiveCommandCount
    }

    func mergedIDs() -> Set<UUID>? { lastMergedIDs }

    private func apply(_ command: SnipLibraryCommand) throws -> SnipLibraryOutcome {
        let outcome: SnipLibraryOutcome
        switch command {
        case .add(
            let content, let origin, let source, let listID, let attachmentURLs, let requestID,
            let now
        ):
            lastAddedAttachmentURLs = attachmentURLs
            let snip = Snip(
                requestID: requestID,
                createdAt: now,
                content: content,
                origin: origin,
                source: source,
                listID: listID,
                manualPosition: nextTopPosition(in: listID)
            )
            snips.append(snip)
            outcome = .add(.added(snip.id))
        case .update(let id, let content, _, _, let now):
            guard let index = snips.firstIndex(where: { $0.id == id }) else {
                throw SnipLibraryError.snipNotFound
            }
            snips[index].content = content
            snips[index].updatedAt = now
            outcome = .none
        case .editAttachments(let snipID, let content, let edits, _, let now):
            guard let index = snips.firstIndex(where: { $0.id == snipID }) else {
                throw SnipLibraryError.snipNotFound
            }
            lastAttachmentEdit = (snipID, content, edits)
            snips[index].content = content
            snips[index].updatedAt = now
            outcome = .none
        case .merge(let ids, let now):
            lastMergedIDs = ids
            let merged = Snip(createdAt: now, content: "Controlled merge result", origin: .quickEntry)
            snips.removeAll { ids.contains($0.id) }
            snips.append(merged)
            outcome = .merged(merged)
        case .delete(let ids):
            if failsDeletion { throw SnipLibraryError.snipNotFound }
            snips.removeAll { ids.contains($0.id) }
            outcome = .none
        case .pruneAttachments(let retainedIDs):
            attachmentPruneCalls += 1
            attachmentRetentionCalls.append(retainedIDs)
            outcome = .none
        case .restore(let restored):
            let existing = Set(snips.map(\.id))
            snips.append(contentsOf: restored.filter { !existing.contains($0.id) })
            outcome = .none
        case .setDone(let ids, let done):
            for index in snips.indices where ids.contains(snips[index].id) {
                snips[index].isDone = done
                snips[index].updatedAt = Date()
            }
            outcome = .none
        case .place(let ids, let listID, let destinationID, let sortMode):
            let moving = Set(ids)
            var destination = Snip.sorted(
                snips.filter { $0.listID == listID && !moving.contains($0.id) },
                by: sortMode
            ).map(\.id)
            let insertion = destinationID.flatMap(destination.firstIndex) ?? destination.endIndex
            destination.insert(contentsOf: ids, at: insertion)
            let sourceLists = Set(snips.filter { moving.contains($0.id) }.map(\.listID))
            for index in snips.indices where moving.contains(snips[index].id) {
                snips[index].listID = listID
            }
            reindex(listID: listID, orderedIDs: destination)
            for sourceList in sourceLists where sourceList != listID { reindex(listID: sourceList) }
            outcome = .none
        case .applyDevicePatch(let patch, _):
            guard let updated = patch.applying(to: makeSnapshot(sortMode: .manual)) else {
                throw SnipLibraryError.deviceActionChanged
            }
            snips = updated.snips
            lists = updated.lists
            outcome = .none
        case .restoreReplacing(let restored, let id, let expectedUpdatedAt):
            guard let current = snips.first(where: { $0.id == id }),
                current.updatedAt == expectedUpdatedAt
            else { throw SnipLibraryError.snipChanged }
            snips.removeAll { $0.id == id }
            snips.append(contentsOf: restored)
            outcome = .none
        case .moveChronologically(let ids, let listID):
            for index in snips.indices where ids.contains(snips[index].id) {
                snips[index].listID = listID
                snips[index].manualPosition = nextTopPosition(in: listID, excluding: Set(ids))
            }
            outcome = .none
        case .createList(let proposedName, let systemImage, let color, let namePolicy):
            var name = proposedName
            if namePolicy == .available {
                var suffix = 2
                while lists.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    name = "\(proposedName) (\(suffix))"
                    suffix += 1
                }
            }
            guard !lists.contains(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else { throw SnipLibraryError.duplicateList }
            let list = SnipList(
                id: UUID(),
                name: name,
                systemImage: systemImage,
                color: color,
                position: lists.count
            )
            lists.append(list)
            outcome = .listCreated(list)
        case .restoreList(let list):
            guard !lists.contains(where: { $0.id == list.id }),
                !lists.contains(where: {
                    $0.name.caseInsensitiveCompare(list.name) == .orderedSame
                })
            else { throw SnipLibraryError.invalidList }
            for index in lists.indices where lists[index].position >= list.position {
                lists[index].position += 1
            }
            lists.append(list)
            outcome = .none
        case .updateList(let id, let name, let systemImage, let color):
            guard let index = lists.firstIndex(where: { $0.id == id }) else {
                throw SnipLibraryError.invalidList
            }
            guard !lists.contains(where: {
                $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else { throw SnipLibraryError.duplicateList }
            lists[index].name = name
            lists[index].systemImage = systemImage
            if case .set(let value) = color { lists[index].color = value }
            outcome = .none
        case .deleteList(let id):
            if failsListDeletion { throw SnipLibraryError.snipNotFound }
            lists.removeAll { $0.id == id }
            for index in snips.indices where snips[index].listID == id {
                snips[index].listID = SnipList.inboxID
            }
            for index in lists.indices { lists[index].position = index }
            outcome = .none
        case .batch(let commands):
            var last: SnipLibraryOutcome = .none
            for command in commands {
                let next = try apply(command)
                if next != .none { last = next }
            }
            outcome = last
        case .guarded(let expectation, let command):
            let snipsByID = Dictionary(uniqueKeysWithValues: snips.map { ($0.id, $0) })
            let listsByID = Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0) })
            guard expectation.expectedSnips.allSatisfy({ snipsByID[$0.id] == $0 }),
                expectation.absentSnipIDs.allSatisfy({ snipsByID[$0] == nil }),
                expectation.expectedLists.allSatisfy({ listsByID[$0.id] == $0 }),
                expectation.absentListIDs.allSatisfy({ listsByID[$0] == nil }),
                expectation.requiredListIDs.allSatisfy({ listsByID[$0] != nil }),
                expectation.expectedListMemberships.allSatisfy({ listID, expectedIDs in
                    listsByID[listID] != nil
                        && Set(snips.lazy.filter { $0.listID == listID }.map(\.id)) == expectedIDs
                })
            else { throw SnipLibraryError.snipChanged }
            outcome = try apply(command)
        default:
            outcome = .none
        }
        return outcome
    }

    private func makeSnapshot(sortMode: SnipSortMode) -> SnipLibrarySnapshot {
        let orderedSnips = lists.sorted { $0.position < $1.position }.flatMap { list in
            Snip.sorted(snips.filter { $0.listID == list.id }, by: sortMode)
        }
        let orderedLists = lists.sorted { $0.position < $1.position }
        return SnipLibrarySnapshot(
            snips: canonicalRoundTrip(orderedSnips),
            lists: canonicalRoundTrip(orderedLists),
            attachmentURLs: attachmentURLs
        )
    }

    private func canonicalRoundTrip<Value: Codable>(_ value: Value) -> Value {
        guard let data = try? JSONEncoder().encode(value),
            let decoded = try? JSONDecoder().decode(Value.self, from: data)
        else { return value }
        return decoded
    }

    private func nextTopPosition(in listID: UUID, excluding: Set<UUID> = []) -> Int64 {
        (snips.filter { $0.listID == listID && !excluding.contains($0.id) }
            .map(\.manualPosition).min() ?? 1) - 1
    }

    private func reindex(listID: UUID, orderedIDs: [UUID]? = nil) {
        let ids = orderedIDs ?? Snip.sorted(
            snips.filter { $0.listID == listID },
            by: .manual
        ).map(\.id)
        for (position, id) in ids.enumerated() {
            guard let index = snips.firstIndex(where: { $0.id == id }) else { continue }
            snips[index].manualPosition = Int64(position)
        }
    }
}
