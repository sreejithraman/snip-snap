import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import Synchronization
import XCTest

final class CloudFailedEnableReviewTests: XCTestCase {
    func testUnarmedFreshSetupRetriesWithItsOriginalIDWithoutReview() async throws {
        let crash = ReviewCrashSwitch()
        let f = try await fixture(crash: crash)
        defer { try? FileManager.default.removeItem(at: f.root) }
        crash.arm(.afterFirstSendStarted)
        do {
            _ = try await f.mode.enableOrRetry()
            XCTFail("Expected the pre-send interruption")
        } catch ReviewFixtureError.injected {}
        let before = try await f.persistence.snapshot()
        let bundle = try XCTUnwrap(try FailedEnableEvidenceFile(root: f.root).read(before.activeStore.id))
        let capture = try XCTUnwrap(bundle.namespaces.flatMap(\.captures).last)
        XCTAssertFalse(capture.armed)
        let events = await f.transports.events()
        XCTAssertFalse(events.contains { if case .sent = $0 { true } else { false } })
        let reopened = try SwiftDataSyncModePersistence(rootURL: f.root)
        let mode = coordinator(reopened, fixture: f)
        let result = try await mode.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let final = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.map(\.id), [f.snip.id])
        XCTAssertEqual(final.snips.first?.content, "review fixture")
        let review = try await SnipSyncModeStore(reopened).failedEnableReview.snapshot()
        XCTAssertTrue(review.issues.isEmpty)
    }

    func testStaleSourceExpectationRequiresFreshChoiceAndThenFinishesOn() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let issue = try await publishIssue(f)
        let facade = SnipSyncModeStore(f.persistence).failedEnableReview
        let first = try await facade.choose(issue.id, selection: .recoverAsNew, expecting: issue.expectation)
        let local = try await f.persistence.activeLibrary()
        _ = try await local.perform(.add(content: "new local work", origin: .quickEntry, source: nil,
            listID: SnipList.inbox.id, attachmentURLs: [], requestID: UUID(),
            now: Date(timeIntervalSince1970: 30)), sortedBy: .manual)
        let eventsBefore = await f.transports.events()
        do {
            _ = try await facade.choose(issue.id, selection: .recoverAsNew, expecting: issue.expectation)
            XCTFail("The source snapshot changed")
        } catch FailedEnableSetupReviewReadError.staleComparison {}
        let eventsAfter = await f.transports.events()
        XCTAssertEqual(eventsAfter, eventsBefore)
        let waiting = try await f.mode.enableOrRetry()
        XCTAssertEqual(waiting.state, .needsAttention)
        let view = try await facade.snapshot()
        XCTAssertEqual(view.issues.first(where: { $0.id == issue.id })?.selection, first)
        let fresh = try XCTUnwrap(view.issues.first { $0.allowedChoices == [.recoverAsNew] })
        XCTAssertNotEqual(fresh.id, issue.id)
        let chosen = try await facade.choose(fresh.id, selection: .recoverAsNew, expecting: fresh.expectation)
        let status = try await f.mode.enableOrRetry()
        XCTAssertEqual(status.state, .on)
        let final = try await f.persistence.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.map(\.content).sorted(), ["new local work", "review fixture"])
        let output = try XCTUnwrap(chosen.outputs.first)
        guard case .snip(let outputID) = output.output else { return XCTFail("Expected a snip") }
        XCTAssertTrue(final.snips.contains { $0.id == outputID })
        XCTAssertFalse(final.snips.contains { $0.id == f.snip.id })
    }

    func testChangedServerInvalidatesRecoveryBeforeSendAndFreshDeviceChoiceFinishesOn() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let issue = try await publishIssue(f)
        let facade = SnipSyncModeStore(f.persistence).failedEnableReview
        let previous = try await facade.choose(issue.id, selection: .recoverAsNew, expecting: issue.expectation)
        let remote = Snip(id: f.snip.id, requestID: f.snip.requestID, createdAt: f.snip.createdAt,
            updatedAt: Date(timeIntervalSince1970: 40), content: "server changed", origin: f.snip.origin)
        let writer = FakeCloudRecordTransport(server: f.server, namespace: f.namespace)
        _ = try await writer.send(CloudOutboundBatch(operations: [.save(CloudFullRecordCodec.snipDraft(remote, in: f.zone))]))
        let waiting = try await f.mode.enableOrRetry()
        XCTAssertEqual(waiting.state, .needsAttention)
        let eventsBeforeStaleChoice = await f.transports.events()
        do {
            _ = try await facade.choose(issue.id, selection: .recoverAsNew, expecting: issue.expectation)
            XCTFail("The checked server comparison changed")
        } catch FailedEnableSetupReviewReadError.staleComparison {}
        let eventsAfterStaleChoice = await f.transports.events()
        XCTAssertEqual(eventsAfterStaleChoice, eventsBeforeStaleChoice)
        let oldOutput = try XCTUnwrap(previous.outputs.first)
        guard case .snip(let unusedID) = oldOutput.output else { return XCTFail("Expected a snip") }
        let notCreated = await f.server.fullSnapshot(for: .snip(unusedID, in: f.zone))
        XCTAssertNil(notCreated)
        let view = try await facade.snapshot()
        let fresh = try XCTUnwrap(view.issues.first { $0.allowedChoices == [.useDevice] })
        guard case .snip(let server)? = fresh.serverFieldsAtReview else { return XCTFail("Expected checked fields") }
        XCTAssertEqual(server.content, "server changed")
        XCTAssertEqual(view.issues.first(where: { $0.id == issue.id })?.selection, previous)
        _ = try await facade.choose(fresh.id, selection: .useDevice, expecting: fresh.expectation)
        let result = try await f.mode.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let final = try await f.persistence.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.map(\.id), [f.snip.id])
        XCTAssertEqual(final.snips.first?.content, "review fixture")
        let remoteTexts = await f.server.storedTextValues()
        XCTAssertEqual(remoteTexts, ["review fixture"])
    }

    func testAccountGenerationAndIssueCASRejectEffectsThenFreshChoiceFinishesOn() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let issue = try await publishIssue(f)
        let facade = SnipSyncModeStore(f.persistence).failedEnableReview
        let before = await f.transports.events()
        await f.account.set(.available(accountLineage: "another account"))
        let unavailable = try await facade.snapshot()
        XCTAssertTrue(unavailable.issues.allSatisfy { $0.serverState == .unavailable && $0.allowedChoices.isEmpty })
        do {
            _ = try await facade.choose(issue.id, selection: .recoverAsNew, expecting: issue.expectation)
            XCTFail("Wrong account")
        } catch FailedEnableSetupReviewReadError.accountUnavailable {}
        await f.account.set(.available(accountLineage: "account"))
        let wrongNamespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "account",
            generation: UUID(), zones: [f.zone])
        let wrong = ICloudSyncModeCoordinator(persistence: f.persistence, namespace: wrongNamespace,
            textZone: f.zone, makeTransport: { f.transports.make() }, accountStateSource: f.account)
        do {
            _ = try await wrong.enableOrRetry()
            XCTFail("Wrong generation")
        } catch SyncModePersistenceError.transitionInProgress {}
        let after = await f.transports.events()
        XCTAssertEqual(after, before)
        _ = try await f.mode.enableOrRetry()
        let refreshed = try await facade.snapshot()
        let current = try XCTUnwrap(refreshed.issues.first { !$0.allowedChoices.isEmpty })
        let invalid = FailedEnableSetupExpectation(sourceStoreID: current.expectation.sourceStoreID,
            issueID: current.id, issueDigest: String(repeating: "0", count: 64), sequence: current.expectation.sequence)
        do {
            _ = try await facade.choose(current.id, selection: .recoverAsNew, expecting: invalid)
            XCTFail("Wrong issue digest")
        } catch FailedEnableSetupReviewReadError.staleComparison {}
        let invalidExpectations = [
            FailedEnableSetupExpectation(sourceStoreID: UUID(), issueID: current.id,
                issueDigest: current.expectation.issueDigest, sequence: current.expectation.sequence),
            FailedEnableSetupExpectation(sourceStoreID: current.expectation.sourceStoreID, issueID: UUID(),
                issueDigest: current.expectation.issueDigest, sequence: current.expectation.sequence),
            FailedEnableSetupExpectation(sourceStoreID: current.expectation.sourceStoreID, issueID: current.id,
                issueDigest: current.expectation.issueDigest, sequence: "0")
        ]
        let beforeInvalidChoices = await f.transports.events()
        for expectation in invalidExpectations {
            do {
                _ = try await facade.choose(current.id, selection: .recoverAsNew, expecting: expectation)
                XCTFail("Stale source, issue or bundle sequence")
            } catch FailedEnableSetupReviewReadError.staleComparison {}
        }
        let afterInvalidChoices = await f.transports.events()
        XCTAssertEqual(afterInvalidChoices, beforeInvalidChoices)
        let chosen = try await facade.choose(current.id, selection: .recoverAsNew, expecting: current.expectation)
        let result = try await f.mode.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let final = try await f.persistence.activeLibrary().checkedSnapshot(sortedBy: .manual)
        let map = try XCTUnwrap(chosen.outputs.first)
        guard case .snip(let outputID) = map.output else { return XCTFail("Expected a snip") }
        XCTAssertEqual(final.snips.map(\.id), [outputID])
        XCTAssertEqual(final.snips.first?.content, "review fixture")
        let values = await f.server.storedTextValues()
        XCTAssertEqual(values, ["review fixture"])
    }

    func testRecoveryChoiceSurvivesOfflineCancelReopenAndRepeatedContinueWithOneMap() async throws {
        let f = try await fixture(bytes: Data("saved review bytes".utf8))
        defer { try? FileManager.default.removeItem(at: f.root) }
        let issue = try await publishIssue(f)
        let facade = SnipSyncModeStore(f.persistence).failedEnableReview
        let before = await f.transports.events()
        let chosen = try await facade.choose(issue.id, selection: .recoverAsNew, expecting: issue.expectation)
        await f.account.set(.noAccount)
        try await facade.keepLocalOnly()
        let after = await f.transports.events()
        XCTAssertEqual(after, before)
        let off = try await f.persistence.snapshot()
        XCTAssertNil(off.transition)
        XCTAssertEqual(off.activeStore.kind, .localOnly)
        let localAfterCancel = try await f.persistence.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(localAfterCancel.snips.map(\.id), [f.snip.id])
        XCTAssertEqual(localAfterCancel.snips.first?.content, "review fixture")
        let reopened = try SwiftDataSyncModePersistence(rootURL: f.root)
        let offlineReview = try await SnipSyncModeStore(reopened).failedEnableReview.snapshot()
        XCTAssertEqual(offlineReview.issues.first(where: { $0.id == issue.id })?.selection, chosen)
        await f.account.set(.available(accountLineage: "account"))
        let mode = coordinator(reopened, fixture: f)
        let newFacade = SnipSyncModeStore(reopened).failedEnableReview
        let result = try await mode.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let final = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.map(\.content), ["review fixture"])
        let repeated = try await mode.enableOrRetry()
        XCTAssertEqual(repeated.state, .on)
        let again = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(Set(again.snips.map(\.id)), Set(final.snips.map(\.id)))
        let records = try await newFacade.snapshot()
        XCTAssertEqual(records.issues.first(where: { $0.id == issue.id })?.selection, chosen)
        let copy = try XCTUnwrap(final.snips.first { $0.content == "review fixture" })
        let attachment = try XCTUnwrap(copy.attachments.first)
        let url = try XCTUnwrap(final.attachmentURLs[attachment.id])
        XCTAssertEqual(try Data(contentsOf: url), Data("saved review bytes".utf8))
        let roots = try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("stores").path)
        XCTAssertGreaterThan(roots.count, 1, "Old evidence roots stay retained")
    }

    func testKeepOffLeavesSourceWritableWithoutNetworkOrPromotion() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let issue = try await publishIssue(f)
        let facade = SnipSyncModeStore(f.persistence).failedEnableReview
        let before = await f.transports.events()
        await f.account.set(.noAccount)
        try await facade.keepLocalOnly()
        let local = try await f.persistence.activeLibrary()
        _ = try await local.perform(.update(id: f.snip.id, content: "changed while off",
            attachmentURLs: nil, expectedUpdatedAt: f.snip.updatedAt,
            now: Date(timeIntervalSince1970: 50)), sortedBy: .manual)
        let after = await f.transports.events()
        XCTAssertEqual(after, before)
        let storage = try await f.persistence.snapshot()
        XCTAssertNil(storage.transition)
        XCTAssertEqual(storage.activeStore.kind, .localOnly)
        let content = try await local.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(content.snips.first?.content, "changed while off")
        let saved = try await facade.snapshot()
        XCTAssertTrue(saved.issues.contains { $0.id == issue.id })
        XCTAssertTrue(saved.issues.allSatisfy { $0.serverState == .unavailable })
    }

    func testDistinctEarlierLocalVersionStaysAvailableAndBlocksActivation() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let issue = try await publishIssue(f)
        let facade = SnipSyncModeStore(f.persistence).failedEnableReview
        let chosen = try await facade.choose(issue.id, selection: .recoverAsNew, expecting: issue.expectation)
        let local = try await f.persistence.activeLibrary()
        _ = try await local.perform(.update(id: f.snip.id, content: "newer device value",
            attachmentURLs: nil, expectedUpdatedAt: f.snip.updatedAt,
            now: Date(timeIntervalSince1970: 60)), sortedBy: .manual)
        let waiting = try await f.mode.enableOrRetry()
        XCTAssertEqual(waiting.state, .needsAttention)
        let saved = try await facade.snapshot()
        XCTAssertEqual(saved.issues.first(where: { $0.id == issue.id })?.selection, chosen)
        XCTAssertTrue(saved.issues.allSatisfy { $0.allowedChoices.isEmpty })
        XCTAssertTrue(saved.issues.contains { row in row.earlierLocalVersions.contains {
            if case .snip(let value) = $0 { return value.content == "review fixture" }
            return false
        } })
        try await facade.keepLocalOnly()
        let storage = try await f.persistence.snapshot()
        XCTAssertNil(storage.transition)
        let content = try await f.persistence.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(content.snips.first?.content, "newer device value")
    }

    func testChosenOutputReplaysDecisionApplyAndPointerCrashes() async throws {
        for point: SyncModeCrashPoint in [.afterFailedEnableReviewDecision, .afterCandidateMergeDurability,
                                         .beforePointerSwap, .afterPointerSwap] {
            let crash = ReviewCrashSwitch()
            let f = try await fixture(crash: crash)
            defer { try? FileManager.default.removeItem(at: f.root) }
            let issue = try await publishIssue(f)
            let facade = SnipSyncModeStore(f.persistence).failedEnableReview
            if point == .afterFailedEnableReviewDecision { crash.arm(point) }
            do {
                _ = try await facade.choose(issue.id, selection: .recoverAsNew, expecting: issue.expectation)
                if point == .afterFailedEnableReviewDecision { XCTFail("Expected decision publication interruption") }
            } catch ReviewFixtureError.injected {}
            let saved = try await facade.snapshot()
            let selection = try XCTUnwrap(saved.issues.first(where: { $0.id == issue.id })?.selection)
            if point != .afterFailedEnableReviewDecision {
                crash.arm(point)
                do {
                    _ = try await f.mode.enableOrRetry()
                    XCTFail("Expected the selected boundary")
                } catch ReviewFixtureError.injected {}
            }
            let reopened = try SwiftDataSyncModePersistence(rootURL: f.root)
            let mode = coordinator(reopened, fixture: f)
            let result = try await mode.enableOrRetry()
            XCTAssertEqual(result.state, .on)
            let final = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
            let map = try XCTUnwrap(selection.outputs.first)
            guard case .snip(let expectedID) = map.output else { return XCTFail("Expected mapped snip") }
            XCTAssertEqual(final.snips.map(\.id), [expectedID])
            XCTAssertEqual(final.snips.first?.content, "review fixture")
            let next = try await mode.enableOrRetry()
            XCTAssertEqual(next.state, .on)
            let again = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
            XCTAssertEqual(again.snips.map(\.id), [expectedID])
        }
    }

    private func publishIssue(_ f: ReviewFixture) async throws -> FailedEnableSetupIssue {
        await f.transports.first.failNextSentItem(.snip(f.snip.id, in: f.zone), failure: .rejected)
        do {
            _ = try await f.mode.enableOrRetry()
            XCTFail("Expected rejected first send")
        } catch let error as CloudSyncIssueError { XCTAssertEqual(error.issue, .appDataIssue) }
        let waiting = try await f.mode.enableOrRetry()
        XCTAssertEqual(waiting.state, .needsAttention)
        let view = try await SnipSyncModeStore(f.persistence).failedEnableReview.snapshot()
        return try XCTUnwrap(view.issues.first { $0.entityID == .snip(f.snip.id) })
    }

    private func fixture(bytes: Data? = nil, crash: ReviewCrashSwitch = ReviewCrashSwitch()) async throws -> ReviewFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FailedEnableReview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, crashHook: { try crash.hit($0) })
        var attachments: [URL] = []
        if let bytes {
            let url = root.appendingPathComponent("review.txt")
            try bytes.write(to: url)
            attachments = [url]
        }
        let local = try await persistence.activeLibrary()
        let added = try await local.perform(.add(content: "review fixture", origin: .quickEntry, source: nil,
            listID: SnipList.inbox.id, attachmentURLs: attachments, requestID: UUID(),
            now: Date(timeIntervalSince1970: 10)), sortedBy: .manual)
        let snip = try XCTUnwrap(added.snapshot.snips.first)
        let zone = CloudZoneID(name: "metadata", ownerName: "owner")
        let payload = bytes == nil ? nil : CloudZoneID(name: "payload", ownerName: "owner")
        let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "account", generation: UUID(),
            zones: Set([zone] + (payload.map { [$0] } ?? [])))
        let server = FakeCloudServer()
        let account = ReviewAccountSource()
        let transports = ReviewTransportFactory(server: server, namespace: namespace)
        let mode = ICloudSyncModeCoordinator(persistence: persistence, namespace: namespace, textZone: zone,
            payloadZone: payload, makeTransport: { transports.make() }, accountStateSource: account)
        return ReviewFixture(root: root, persistence: persistence, mode: mode, snip: snip, zone: zone,
            payload: payload, namespace: namespace, server: server, account: account, transports: transports)
    }

    private func coordinator(_ persistence: SwiftDataSyncModePersistence, fixture f: ReviewFixture) -> ICloudSyncModeCoordinator {
        ICloudSyncModeCoordinator(persistence: persistence, namespace: f.namespace, textZone: f.zone,
            payloadZone: f.payload, makeTransport: { f.transports.make() }, accountStateSource: f.account)
    }
}

private struct ReviewFixture: Sendable {
    let root: URL
    let persistence: SwiftDataSyncModePersistence
    let mode: ICloudSyncModeCoordinator
    let snip: Snip
    let zone: CloudZoneID
    let payload: CloudZoneID?
    let namespace: CloudSyncNamespace
    let server: FakeCloudServer
    let account: ReviewAccountSource
    let transports: ReviewTransportFactory
}

private enum ReviewFixtureError: Error { case injected }

private final class ReviewCrashSwitch: Sendable {
    private let point = Mutex<SyncModeCrashPoint?>(nil)
    func arm(_ value: SyncModeCrashPoint) { point.withLock { $0 = value } }
    func hit(_ value: SyncModeCrashPoint) throws {
        let fails = point.withLock { current in
            guard current == value else { return false }
            current = nil
            return true
        }
        if fails { throw ReviewFixtureError.injected }
    }
}

private actor ReviewAccountSource: ICloudAccountStateSource {
    private var state: ICloudAccountState = .available(accountLineage: "account")
    func currentAccountState() -> ICloudAccountState { state }
    func set(_ value: ICloudAccountState) { state = value }
}

private final class ReviewTransportFactory: Sendable {
    let first: FakeCloudRecordTransport
    private let server: FakeCloudServer
    private let namespace: CloudSyncNamespace
    private let transports = Mutex<[FakeCloudRecordTransport]>([])
    init(server: FakeCloudServer, namespace: CloudSyncNamespace) {
        self.server = server
        self.namespace = namespace
        first = FakeCloudRecordTransport(server: server, namespace: namespace)
    }
    func make() -> FakeCloudRecordTransport {
        transports.withLock { values in
            let value = values.isEmpty ? first : FakeCloudRecordTransport(server: server, namespace: namespace)
            values.append(value)
            return value
        }
    }
    func events() async -> [FakeCloudTransportEvent] {
        let values = transports.withLock { $0 }
        var result: [FakeCloudTransportEvent] = []
        for value in values { result += await value.events() }
        return result
    }
}
