import CloudKit
import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import Synchronization
import SwiftData
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
        XCTAssertEqual(before.transition?.phase, .candidateReady,
            "A pre-send interruption must enter the receipt-retiring retry path")
        let transition = try XCTUnwrap(before.transition)
        let rawCandidate = try await f.persistence.libraryForTransition(storeID: transition.candidateStoreID)
        let completedReceipt = try await rawCandidate.failedEnableC72ReceiptDigest(
            namespace: f.namespace.namespaceKey, transitionID: transition.id)
        XCTAssertNotNil(completedReceipt, "The first candidate apply completed before the interruption")
        let bundle = try XCTUnwrap(try FailedEnableEvidenceFile(root: f.root).read(before.activeStore.id))
        let capture = try XCTUnwrap(bundle.namespaces.flatMap(\.captures).last)
        XCTAssertFalse(capture.armed)
        let applied = try XCTUnwrap(bundle.transfers.last { $0.sourceCaptureIDs == [capture.id] })
        XCTAssertEqual(applied.state, .checked)
        XCTAssertEqual(completedReceipt.map(FailedEnableEncoding.hex), applied.planDigest)
        let events = await f.transports.events()
        XCTAssertFalse(events.contains { if case .sent = $0 { true } else { false } })
        let reopened = try SwiftDataSyncModePersistence(rootURL: f.root)
        let mode = coordinator(reopened, fixture: f)
        let result: ICloudSyncModeStatus
        do {
            result = try await mode.enableOrRetry()
        } catch {
            let facts = await reopened.failedEnableC72Facts()
            XCTFail("[SM23-F5-C72] unarmed retry threw \(error); \(facts)")
            throw error
        }
        let facts: String
        if result.state == .on { facts = "" }
        else { facts = await reopened.failedEnableC72Facts() }
        XCTAssertEqual(result.state, .on, facts)
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
        let facts: String
        if result.state == .on { facts = "" }
        else { facts = await f.persistence.failedEnableC72Facts() }
        XCTAssertEqual(result.state, .on, facts)
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

    func testReviewChoiceSurvivesOnlyTypedJSONMemberOrderChanges() async throws {
        let crash = ReviewCrashSwitch()
        let f = try await fixture(crash: crash)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await publishIssue(f)
        let facade = SnipSyncModeStore(f.persistence).failedEnableReview
        _ = try await facade.choose(first.id, selection: .recoverAsNew, expecting: first.expectation)
        let remote = Snip(id: f.snip.id, requestID: f.snip.requestID, createdAt: f.snip.createdAt,
            updatedAt: Date(timeIntervalSince1970: 40), content: "comparison preimage", origin: f.snip.origin,
            manualSortKey: f.snip.manualSortKey)
        let draft = try CloudFullRecordCodec.snipDraft(remote, in: f.zone)
        var encrypted = draft.encryptedFields
        encrypted["f5ComparisonFuture"] = .string("retained unknown")
        let writer = FakeCloudRecordTransport(server: f.server, namespace: f.namespace)
        _ = try await writer.send(CloudOutboundBatch(operations: [.save(CloudRecordDraft(id: draft.id,
            recordType: draft.recordType, schemaVersion: draft.schemaVersion, routingFields: draft.routingFields,
            encryptedFields: encrypted))]))
        let waiting = try await f.mode.enableOrRetry()
        XCTAssertEqual(waiting.state, .needsAttention)
        let view = try await facade.snapshot()
        let issue = try XCTUnwrap(view.issues.first { $0.allowedChoices == [.useDevice] })
        let receipt = try await facade.choose(issue.id, selection: .useDevice, expecting: issue.expectation)
        XCTAssertTrue(receipt.outputs.isEmpty)
        let state = try await f.persistence.snapshot()
        let transition = try XCTUnwrap(state.transition)
        let read = try await f.persistence.withFailedEnableC72Read(transition: transition) { ($0, $1) }
        let source = read.0.0
        let candidate = read.0.1
        let file = FailedEnableEvidenceFile(root: f.root)
        let evidence = try XCTUnwrap(try file.read(state.activeStore.id))
        let before = try Data(contentsOf: file.url(state.activeStore.id))
        let row = try XCTUnwrap(evidence.namespaces.flatMap(\.reviews).first {
            $0.id == FailedEnableEncoding.uuid(issue.id)
        })
        XCTAssertEqual(row.local.sourceDigest, try source.sourceDigest(sourceID: transition.sourceStoreID))
        XCTAssertEqual(row.local.sourceRevision, String(source.snapshot.revision))
        XCTAssertEqual(row.local.image.value, try source.images().first { $0.reference == row.reference })
        let reference = try row.reference.domain
        let original = try XCTUnwrap(candidate.storage.readyEntities.first { $0.reference == reference })
        let typed = try JSONDecoder().decode(CloudTypedSnipRecord.self, from: original.acceptedData)
        let policy = CloudFailedEnablePolicy(namespace: f.namespace, dataZone: f.zone)
        let ascending = comparisonEntity(original, accepted: try comparisonJSON(original.acceptedData, descending: false),
            presence: try comparisonJSON(original.presenceData, descending: false), revision: original.localRevision + 10)
        let descending = comparisonEntity(original, accepted: try comparisonJSON(original.acceptedData, descending: true),
            presence: try comparisonJSON(original.presenceData, descending: true), revision: original.localRevision + 20)
        XCTAssertNotEqual(ascending.acceptedData, descending.acceptedData)
        XCTAssertNotEqual(ascending.presenceData, descending.presenceData)
        XCTAssertEqual(try JSONDecoder().decode(CloudTypedSnipRecord.self, from: ascending.acceptedData),
            try JSONDecoder().decode(CloudTypedSnipRecord.self, from: descending.acceptedData))
        XCTAssertEqual(try JSONDecoder().decode(CloudTypedSnipRecord.self, from: ascending.presenceData),
            try JSONDecoder().decode(CloudTypedSnipRecord.self, from: descending.presenceData))
        XCTAssertNotEqual(CloudFullReenableAcceptedCAS(ascending), CloudFullReenableAcceptedCAS(descending))
        for value in [ascending, descending] {
            XCTAssertEqual(try JSONDecoder().decode(CloudTypedSnipRecord.self, from: value.acceptedData), typed)
            XCTAssertEqual(try JSONDecoder().decode(CloudTypedSnipRecord.self, from: value.presenceData), typed)
            XCTAssertEqual(value.identity, original.identity)
            XCTAssertEqual(value.schemaVersion, original.schemaVersion)
            XCTAssertEqual(value.dependencyListID, original.dependencyListID)
            XCTAssertEqual(value.shadowData, original.shadowData)
            XCTAssertEqual(value.systemFields, original.systemFields)
            _ = try CloudFailedEnablePolicy.fields(value, namespace: f.namespace.binding)
            let input = FailedEnableReviewRead(source: source, candidate: comparisonCandidate(candidate, replacing: value),
                transition: transition, evidence: evidence)
            let rows = try policy.reviewDrafts(input)
            let applicable = try XCTUnwrap(rows.first { $0.id == row.id })
            XCTAssertEqual(applicable.issueDigest, row.issueDigest)
            XCTAssertEqual(applicable.decision, row.decision)
            XCTAssertEqual(applicable.server, row.server, "Retain the actual original observation bytes")
        }

        let savedDraft = try CloudFullRecordCodec.snipDraft(remote, accepted: typed)
        func changed(_ fields: [String: CloudFieldValue]) throws -> CloudAcceptedEntity {
            let snapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: CloudRecordDraft(
                id: savedDraft.id, recordType: savedDraft.recordType, schemaVersion: savedDraft.schemaVersion,
                routingFields: savedDraft.routingFields, encryptedFields: fields, base: savedDraft.base)))
            let input = try CloudFullBatchPlanner.acceptedInput(CloudFullRecordCodec.snip(from: snapshot), snapshot: snapshot)
            return CloudFailedEnablePolicy.entity(input)
        }
        let missingRecord = try typed.shadow.record()
        missingRecord.encryptedValues["isDone"] = nil
        let missingSnapshot = try CloudKitRecordMapper.snapshot(missingRecord)
        let missingTyped = try CloudFullRecordCodec.snip(from: missingSnapshot)
        XCTAssertEqual(typed.isDone, .value(false))
        XCTAssertEqual(missingTyped.isDone, .missing)
        let missingDone = CloudFailedEnablePolicy.entity(
            try CloudFullBatchPlanner.acceptedInput(missingTyped, snapshot: missingSnapshot))
        let historicalRecord = try typed.shadow.record()
        historicalRecord["schemaVersion"] = Int64(2)
        let historicalSnapshot = try CloudKitRecordMapper.snapshot(historicalRecord)
        let historicalTyped = try CloudFullRecordCodec.snip(from: historicalSnapshot)
        let historicalSchema = CloudFailedEnablePolicy.entity(
            try CloudFullBatchPlanner.acceptedInput(historicalTyped, snapshot: historicalSnapshot))
        XCTAssertEqual(original.schemaVersion, 3)
        XCTAssertEqual(typed.schemaVersion, 3)
        XCTAssertEqual(historicalSnapshot.routingFields["schemaVersion"], .int64(2))
        XCTAssertEqual(historicalSnapshot.schemaVersion, 2)
        XCTAssertEqual(historicalTyped.schemaVersion, 2)
        XCTAssertEqual(historicalSchema.schemaVersion, 2)
        let unknownChanged = try changed(["f5ComparisonFuture": .string("different unknown")])
        let system = try CloudRecordShadow(data: typed.shadow.data, systemFields: Data("different local comparison token".utf8))
        let changedTyped = CloudTypedSnipRecord(storageVersion: typed.storageVersion, id: typed.id,
            domainID: typed.domainID, binding: typed.binding, schemaVersion: typed.schemaVersion,
            requestID: typed.requestID, createdAt: typed.createdAt, updatedAt: typed.updatedAt, origin: typed.origin,
            text: typed.text, source: typed.source, isDone: typed.isDone, pinnedAt: typed.pinnedAt,
            placement: typed.placement, shadow: system)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let systemJSON = try encoder.encode(changedTyped)
        let systemChanged = comparisonEntity(original, accepted: systemJSON, presence: systemJSON,
            systemFields: system.systemFields)
        let extraObject = try JSONSerialization.jsonObject(with: original.acceptedData)
        var extra = try XCTUnwrap(extraObject as? [String: Any])
        extra["futureTypedMember"] = ["first", "second"]
        let extraJSON = try JSONSerialization.data(withJSONObject: extra, options: [.sortedKeys])
        let changedRequestID = UUID()
        let changedListID = UUID()
        let variants: [(String, CloudAcceptedEntity)] = [
            ("field", try changed(["text": .string("different server value")])),
            ("presence", missingDone),
            ("immutable", try changed(["requestID": .string(changedRequestID.uuidString.lowercased())])),
            ("schema", historicalSchema),
            ("dependency", try changed(["listID": .string(changedListID.uuidString.lowercased())])),
            ("system", systemChanged), ("shadow and unknown field", unknownChanged),
            ("unknown typed member", comparisonEntity(original, accepted: extraJSON, presence: original.presenceData))]
        XCTAssertEqual(try CloudFailedEnablePolicy.fields(missingDone, namespace: f.namespace.binding),
            try CloudFailedEnablePolicy.fields(original, namespace: f.namespace.binding))
        XCTAssertEqual(try CloudFailedEnablePolicy.fields(unknownChanged, namespace: f.namespace.binding),
            try CloudFailedEnablePolicy.fields(original, namespace: f.namespace.binding))
        for (name, value) in variants {
            let actual = try JSONDecoder().decode(CloudTypedSnipRecord.self, from: value.acceptedData)
            let snapshot = try CloudKitRecordMapper.snapshot(actual.shadow.record())
            switch name {
            case "field":
                XCTAssertEqual(actual.text, .value("different server value"))
                XCTAssertNotEqual(actual.text, typed.text)
            case "presence":
                XCTAssertNil(snapshot.encryptedFields["isDone"])
                XCTAssertEqual(actual.isDone, .missing)
                XCTAssertNotEqual(actual.isDone, typed.isDone)
            case "immutable":
                XCTAssertEqual(actual.requestID, .value(changedRequestID))
                XCTAssertNotEqual(actual.requestID, typed.requestID)
            case "schema":
                XCTAssertEqual(actual.schemaVersion, 2)
                XCTAssertEqual(snapshot.schemaVersion, 2)
                XCTAssertNotEqual(actual.schemaVersion, typed.schemaVersion)
            case "dependency":
                XCTAssertEqual(snapshot.encryptedFields["listID"], .string(changedListID.uuidString.lowercased()))
                XCTAssertEqual(value.dependencyListID, changedListID)
                XCTAssertNotEqual(value.dependencyListID, original.dependencyListID)
                XCTAssertNotEqual(actual.placement, typed.placement)
            case "system":
                XCTAssertEqual(value.systemFields, Data("different local comparison token".utf8))
                XCTAssertEqual(actual.shadow.systemFields, value.systemFields)
                XCTAssertNotEqual(value.systemFields, original.systemFields)
                XCTAssertEqual(actual.shadow.data, typed.shadow.data)
            case "shadow and unknown field":
                XCTAssertEqual(snapshot.encryptedFields["f5ComparisonFuture"], .string("different unknown"))
                XCTAssertEqual(try CloudKitRecordMapper.snapshot(typed.shadow.record()).encryptedFields["f5ComparisonFuture"],
                    .string("retained unknown"))
            case "unknown typed member":
                let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: value.acceptedData) as? [String: Any])
                let originalObject = try XCTUnwrap(extraObject as? [String: Any])
                XCTAssertNil(originalObject["futureTypedMember"])
                XCTAssertEqual(object["futureTypedMember"] as? [String], ["first", "second"])
                XCTAssertEqual(actual, typed)
            default:
                XCTFail("Missing input discriminant for \(name)")
            }
            _ = try CloudFailedEnablePolicy.fields(value, namespace: f.namespace.binding)
            let rows = try policy.reviewDrafts(FailedEnableReviewRead(source: source,
                candidate: comparisonCandidate(candidate, replacing: value), transition: transition, evidence: evidence))
            let fresh = try XCTUnwrap(rows.first { $0.reference == row.reference }, name)
            XCTAssertNil(fresh.decision.value, name)
            XCTAssertNotEqual(fresh.issueDigest, row.issueDigest, name)
        }
        var precisionDigests: [String] = []
        for literal in ["9007199254740992.0", "9007199254740993.0"] {
            let json = Data(original.acceptedData.dropLast()) + Data(",\"futurePrecision\":\(literal)}".utf8)
            XCTAssertTrue(String(decoding: json, as: UTF8.self).hasSuffix(",\"futurePrecision\":\(literal)}"))
            XCTAssertEqual(try JSONDecoder().decode(CloudTypedSnipRecord.self, from: json), typed)
            let value = comparisonEntity(original, accepted: json, presence: original.presenceData)
            let rows = try policy.reviewDrafts(FailedEnableReviewRead(source: source,
                candidate: comparisonCandidate(candidate, replacing: value), transition: transition, evidence: evidence))
            precisionDigests.append(try XCTUnwrap(rows.first { $0.reference == row.reference }).issueDigest)
        }
        XCTAssertNotEqual(precisionDigests[0], precisionDigests[1], "Unknown numbers must not be rounded into equality")
        let badIdentity = CloudAcceptedEntity(reference: original.reference,
            identity: CloudTextStorageIdentity(zoneName: "other-zone", ownerName: "owner", recordName: original.identity.recordName),
            schemaVersion: original.schemaVersion, acceptedData: original.acceptedData, presenceData: original.presenceData,
            shadowData: original.shadowData, systemFields: original.systemFields,
            dependencyListID: original.dependencyListID, isDeferred: false, localRevision: original.localRevision)
        XCTAssertEqual(badIdentity.identity.zoneName, "other-zone")
        XCTAssertNotEqual(badIdentity.identity, original.identity)
        XCTAssertEqual(badIdentity.acceptedData, original.acceptedData)
        XCTAssertThrowsError(try policy.reviewDrafts(FailedEnableReviewRead(source: source,
            candidate: comparisonCandidate(candidate, replacing: badIdentity), transition: transition, evidence: evidence)))
        let duplicate = Data(("{\"storageVersion\":1," + String(decoding: ascending.acceptedData.dropFirst(), as: UTF8.self)).utf8)
        XCTAssertEqual(String(decoding: ascending.acceptedData, as: UTF8.self)
            .components(separatedBy: "\"storageVersion\":").count, 2)
        XCTAssertEqual(String(decoding: duplicate, as: UTF8.self)
            .components(separatedBy: "\"storageVersion\":").count, 3)
        let ambiguous = comparisonEntity(original, accepted: duplicate, presence: original.presenceData)
        XCTAssertThrowsError(try policy.reviewDrafts(FailedEnableReviewRead(source: source,
            candidate: comparisonCandidate(candidate, replacing: ambiguous), transition: transition, evidence: evidence)))
        XCTAssertEqual(try Data(contentsOf: file.url(state.activeStore.id)), before)
        let reread = try await f.persistence.withFailedEnableC72Read(transition: transition) { $1 }
        XCTAssertEqual(reread.0.storage, candidate.storage, "Pure comparisons cannot rewrite accepted CAS or archives")

        crash.arm(.beforePointerSwap)
        do {
            _ = try await f.mode.enableOrRetry()
            XCTFail("Expected the selected output interruption")
        } catch ReviewFixtureError.injected {}
        let interrupted = try await f.persistence.snapshot()
        let retry = try XCTUnwrap(interrupted.transition)
        let after = try await f.persistence.withFailedEnableC72Read(transition: retry) { ($0, $1) }
        let completed = try XCTUnwrap(try file.read(interrupted.activeStore.id))
        let applicable = try policy.reviewDrafts(FailedEnableReviewRead(source: after.0.0, candidate: after.0.1,
            transition: retry, evidence: completed))
        XCTAssertEqual(applicable.first(where: { $0.reference == row.reference })?.decision, row.decision)
        let completedGroup = try XCTUnwrap(completed.namespaces.first { $0.binding == FailedEnableBinding(f.namespace.binding) })
        let capture = try XCTUnwrap(completedGroup.captures.last { $0.candidateStoreID == FailedEnableEncoding.uuid(retry.candidateStoreID) })
        let originalObservation = try XCTUnwrap(capture.records.first { $0.reference == row.reference }?.unqualifiedObservation.value)
        let post = try XCTUnwrap(after.0.1.storage.readyEntities.first { $0.reference == reference })
        let postTyped = try CloudFullSyncPersistence.snipRecord(post)
        let postSnip = try XCTUnwrap(after.0.1.snapshot.snips.first { $0.id == f.snip.id })
        let postDraft = try CloudFullRecordCodec.snipDraft(postSnip, accepted: postTyped)
        let driftSnapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: CloudRecordDraft(
            id: postDraft.id, recordType: postDraft.recordType, schemaVersion: postDraft.schemaVersion,
            routingFields: postDraft.routingFields, encryptedFields: ["f5ComparisonFuture": .string("different unknown")],
            base: postDraft.base)))
        let driftInput = try CloudFullBatchPlanner.acceptedInput(CloudFullRecordCodec.snip(from: driftSnapshot), snapshot: driftSnapshot)
        let driftEntity = CloudFailedEnablePolicy.entity(driftInput)
        XCTAssertEqual(driftSnapshot.encryptedFields["f5ComparisonFuture"], .string("different unknown"))
        XCTAssertEqual(try CloudKitRecordMapper.snapshot(postTyped.shadow.record()).encryptedFields["f5ComparisonFuture"],
            .string("retained unknown"))
        XCTAssertEqual(try CloudFailedEnablePolicy.fields(driftEntity, namespace: f.namespace.binding),
            try CloudFailedEnablePolicy.fields(post, namespace: f.namespace.binding))
        let drifted = comparisonCandidate(after.0.1, replacing: driftEntity)
        let observed = try policy.observe(capture: capture, candidate: drifted,
            candidateStoreID: retry.candidateStoreID, namespace: f.namespace.binding)
        XCTAssertEqual(observed.records.first { $0.reference == row.reference }?.unqualifiedObservation.value,
            originalObservation, "A later observation cannot replace the selected output's actual checkpoint")
        let reorderedPost = comparisonEntity(post, accepted: try comparisonJSON(post.acceptedData, descending: true),
            presence: try comparisonJSON(post.presenceData, descending: true))
        XCTAssertEqual(try JSONDecoder().decode(CloudTypedSnipRecord.self, from: reorderedPost.acceptedData), postTyped)
        XCTAssertEqual(try JSONDecoder().decode(CloudTypedSnipRecord.self, from: reorderedPost.presenceData), postTyped)
        XCTAssertEqual(reorderedPost.shadowData, post.shadowData)
        XCTAssertEqual(reorderedPost.systemFields, post.systemFields)
        XCTAssertNoThrow(try policy.validateExposure(capture: capture,
            candidate: comparisonCandidate(after.0.1, replacing: reorderedPost), evidence: completed, requiresAccepted: true))
        XCTAssertThrowsError(try policy.validateExposure(capture: capture, candidate: drifted,
            evidence: completed, requiresAccepted: true))
        let driftedRows = try policy.reviewDrafts(FailedEnableReviewRead(source: after.0.0, candidate: drifted,
            transition: retry, evidence: completed))
        XCTAssertNil(driftedRows.first { $0.reference == row.reference }?.decision.value)
        let result = try await f.mode.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let final = try await f.persistence.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.map(\.id), [f.snip.id])
        XCTAssertEqual(final.snips.first?.content, "review fixture")
        let remoteValue = await f.server.fullSnapshot(for: .snip(f.snip.id, in: f.zone))
        XCTAssertEqual(remoteValue?.encryptedFields["f5ComparisonFuture"], .string("retained unknown"))
        let texts = await f.server.storedTextValues()
        XCTAssertEqual(texts, ["review fixture"])
    }

    private func comparisonJSON(_ data: Data, descending: Bool) throws -> Data {
        let json = try JSONSerialization.jsonObject(with: data)
        let object = try XCTUnwrap(json as? [String: Any])
        let keys = descending ? object.keys.sorted().reversed().map { $0 } : object.keys.sorted()
        let members = try keys.map { key in
            let value = try XCTUnwrap(object[key])
            return try JSONSerialization.data(withJSONObject: [key: value], options: [.sortedKeys]).dropFirst().dropLast()
        }
        return Data("{".utf8) + members.enumerated().reduce(into: Data()) { result, pair in
            if pair.offset > 0 { result.append(contentsOf: ",".utf8) }
            result.append(contentsOf: pair.element)
        } + Data("}".utf8)
    }

    private func comparisonEntity(_ value: CloudAcceptedEntity, accepted: Data, presence: Data,
        systemFields: Data? = nil, revision: UInt64? = nil
    ) -> CloudAcceptedEntity {
        CloudAcceptedEntity(reference: value.reference, identity: value.identity, schemaVersion: value.schemaVersion,
            acceptedData: accepted, presenceData: presence, shadowData: value.shadowData,
            systemFields: systemFields ?? value.systemFields, dependencyListID: value.dependencyListID,
            isDeferred: value.isDeferred, wasMaterializedBeforeDeferral: value.wasMaterializedBeforeDeferral,
            hasUnresolvedLegacyAbsence: value.hasUnresolvedLegacyAbsence, graphRepair: value.graphRepair,
            deferredLocalMutation: value.deferredLocalMutation, localRevision: revision ?? value.localRevision)
    }

    private func comparisonCandidate(_ read: FailedEnableStoreRead, replacing entity: CloudAcceptedEntity) -> FailedEnableStoreRead {
        let stored = read.storage
        return FailedEnableStoreRead(snapshot: read.snapshot, seenRequestIDs: read.seenRequestIDs,
            storage: CloudFullStorageSnapshot(readyEntities: stored.readyEntities.map { $0.reference == entity.reference ? entity : $0 },
                deferredEntities: stored.deferredEntities, pendingDeletes: stored.pendingDeletes,
                conflicts: stored.conflicts, enrolledEntities: stored.enrolledEntities, quarantines: stored.quarantines,
                namespaceState: stored.namespaceState), recoveryDescriptors: read.recoveryDescriptors)
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

// [SM23-F5-C72] Temporary fixture-only facts. No identifiers, content, archives or bytes are logged.
extension SwiftDataSyncModePersistence {
    func failedEnableC72Facts() async -> String {
        var facts = ["[SM23-F5-C72]"]
        let before = manifest
        do {
            guard let active = before.stores.first(where: { $0.id == before.activeStoreID }) else {
                throw SyncModePersistenceError.missingStore
            }
            let storage = SyncModeStorageSnapshot(activeStore: active, transition: before.transition,
                accountIsolation: before.accountIsolation, attentionReason: before.attentionReason,
                hasActiveMutationReservation: before.writeReservation != nil)
            facts += ["active=\(storage.activeStore.kind.rawValue)",
                "attention=\(String(describing: storage.attentionReason))"]
            guard let transition = storage.transition, let namespace = transition.namespace else {
                facts.append("transition=none")
                if let namespace = storage.activeStore.namespace {
                    let url = storeFileURL(storage.activeStore)
                    let locks = try FailedEnableReadLocks(stores: [(storage.activeStore.id, url.appendingPathExtension("lock"))])
                    defer { withExtendedLifetime(locks) {} }
                    let read = try FailedEnableC72StoreRead.read(storeURL: url, revision: storage.activeStore.revision,
                        namespace: namespace, transitionID: nil, locks: locks)
                    let cloud = read.value.storage
                    facts += ["activeNamespace=\(cloud.namespaceState.phase.rawValue)",
                        "activeConflicts=\(cloud.conflicts.count)", "activeDeferred=\(cloud.deferredEntities.count)",
                        "activeRecovery=\(read.recoveryKinds.sorted().joined(separator: ","))"]
                }
                facts.append("manifestStable=\(manifest == before)")
                return facts.joined(separator: "; ")
            }
            facts += ["stage=\(transition.phase.rawValue)", "intent=\(transition.hasDurableFullReenableIntent)",
                "provenance=\(transition.seedProvenance.count)", "attempt=\(transition.sendAttempt != nil)"]
            let checked = try withFailedEnableC72Read(transition: transition) { source, candidate in
                var details: [String] = []
                let bundle = try self.failedEnableFiles.read(transition.sourceStoreID)
                let group = bundle?.namespaces.first { $0.binding == FailedEnableBinding(namespace) }
                let sourceImages = try source.images()
                let candidateImages = try candidate.images()
                let currentSourceDigest = try source.sourceDigest(sourceID: transition.sourceStoreID)
                let continuity = try self.failedEnableContinuityMatches(bundle, source: source,
                    sourceID: transition.sourceStoreID)
                details += ["continuity=\(continuity)", "namespace=\(candidate.storage.namespaceState.phase.rawValue)",
                    "namespaceRevision=\(candidate.storage.namespaceState.revision)",
                    "candidateRevision=\(candidate.snapshot.revision)",
                    "ready=\(candidate.storage.readyEntities.count)", "deferred=\(candidate.storage.deferredEntities.count)",
                    "conflicts=\(candidate.storage.conflicts.count)", "quarantines=\(candidate.storage.quarantines.count)",
                    "deletes=\(candidate.storage.pendingDeletes.count)", "alternatives=\(group?.alternatives.count ?? 0)"]
                var represented: Set<String> = []
                for id in self.failedEnableSourceIDs() {
                    guard let saved = try self.failedEnableFiles.read(id) else { continue }
                    represented.formUnion(saved.namespaces.flatMap(\.captures).map(\.candidateStoreID))
                    for transfer in saved.transfers {
                        represented.insert(transfer.sourceStoreID)
                        represented.insert(transfer.destinationStoreID)
                    }
                }
                let unknownRoots = self.manifest.stores.filter {
                    $0.id != transition.candidateStoreID && $0.id != transition.sourceStoreID
                        && $0.kind == .iCloudSync && $0.namespace == namespace
                        && [.deleting, .retired, .recovery].contains($0.lifecycle)
                        && !represented.contains(FailedEnableEncoding.uuid($0.id))
                }.count
                details.append("unknownRoots=\(unknownRoots)")
                let capture = group?.captures.last {
                    $0.transitionID == FailedEnableEncoding.uuid(transition.id)
                        && $0.candidateStoreID == FailedEnableEncoding.uuid(transition.candidateStoreID)
                }
                let transfer = capture.flatMap { saved in bundle?.transfers.last { $0.sourceCaptureIDs == [saved.id] } }
                details += ["currentCapture=\(capture != nil)", "armed=\(capture?.armed == true)",
                    "currentTransfer=\(transfer?.state.rawValue ?? "none")"]
                for record in capture?.records ?? [] {
                    let output = transfer?.outputs.first { $0.reference == record.reference }
                    let reference = try record.reference.domain
                    let accepted = candidate.storage.readyEntities.first { $0.reference == reference }
                    var qMatches = false
                    var fetchedRevisionMatches = false
                    if let accepted {
                        let value = try CloudFailedEnablePolicy.fields(accepted, namespace: namespace)
                        if let q = record.preparation.value.value { qMatches = CloudFailedEnablePolicy.same(q.fields, value) }
                        fetchedRevisionMatches = record.preparation.fetchedDigest.value == (try
                            CloudFailedEnablePolicy.acceptedRevisionDigest(accepted,
                                namespaceRevision: candidate.storage.namespaceState.revision))
                    }
                    let outputMatches = output != nil && candidateImages.first {
                        $0.reference == record.reference
                    } == output
                    var decisionBound = false
                    if let capture, let bundle {
                        decisionBound = self.hasFailedEnableReviewDecision(record, capture: capture, bundle: bundle)
                    }
                    details.append("record[\(record.reference.kind.rawValue)]=\(record.preparation.classification.rawValue)/\(record.preparation.baseKind.rawValue),Q=\(record.preparation.value.value != nil),observed=\(record.observedAccepted.value != nil),choiceBound=\(decisionBound),output=\(outputMatches),acceptedQ=\(qMatches),fetchedCAS=\(fetchedRevisionMatches)")
                }
                if let semantics = self.failedEnableSemantics {
                    if let policy = semantics as? CloudFailedEnablePolicy {
                        var seen: Set<FailedEnableReference> = []
                        for saved in (group?.captures ?? []).sorted(by: {
                            (UInt64($0.ordinal) ?? 0) > (UInt64($1.ordinal) ?? 0)
                        }) {
                            for record in saved.records where seen.insert(record.reference).inserted {
                                var qualified = false
                                if let observed = record.observedAccepted.value {
                                    qualified = try policy.qualifies(record, observation: observed, candidate: nil)
                                }
                                let present = sourceImages.contains { $0.reference == record.reference }
                                let reviewed = group?.reviews.contains { $0.reference == record.reference } == true
                                details.append("strand[\(record.reference.kind.rawValue)]=\(record.preparation.classification.rawValue)/\(record.preparation.baseKind.rawValue),sourcePresent=\(present),ancestry=\(qualified),review=\(reviewed)")
                            }
                        }
                    }
                    if let capture, let bundle {
                        for requiresAccepted in [false, true] {
                            do {
                                try semantics.validateExposure(capture: capture, candidate: candidate,
                                    evidence: bundle, requiresAccepted: requiresAccepted)
                                details.append("exposure[\(requiresAccepted)]=valid")
                            } catch {
                                let code = (error as? FailedEnableEvidenceError).map { String(describing: $0) }
                                    ?? String(reflecting: type(of: error))
                                details.append("exposure[\(requiresAccepted)]=\(code)")
                            }
                        }
                    }
                    do {
                        let drafts = try semantics.reviewDrafts(FailedEnableReviewRead(source: source,
                            candidate: candidate, transition: transition, evidence: bundle))
                        details.append("drafts=\(drafts.count)")
                        for row in group?.reviews ?? [] {
                            let draft = drafts.first { $0.id == row.id }
                            var comparisons: [String] = []
                            let reference = try row.reference.domain
                            if let observation = row.server.observation.value,
                                let actual = candidate.storage.readyEntities.first(where: { $0.reference == reference }) {
                                let saved = try JSONDecoder().decode(CloudAcceptedEntityInput.self, from: observation.entityBase64)
                                let savedFields = try CloudFailedEnablePolicy.fields(CloudFailedEnablePolicy.entity(saved), namespace: namespace)
                                let actualFields = try CloudFailedEnablePolicy.fields(actual, namespace: namespace)
                                comparisons += ["fields=\(savedFields == actualFields)",
                                    "userFields=\(CloudFailedEnablePolicy.same(savedFields, actualFields))",
                                    "identity=\(saved.identity == actual.identity)",
                                    "acceptedBytes=\(saved.acceptedData == actual.acceptedData)",
                                    "presenceBytes=\(saved.presenceData == actual.presenceData)",
                                    "shadowBytes=\(saved.shadowData == actual.shadowData)",
                                    "systemFields=\(saved.systemFields == actual.systemFields)",
                                    "dependency=\(saved.dependencyListID == actual.dependencyListID)"]
                            }
                            let localMatches = sourceImages.first { $0.reference == row.reference } == row.local.image.value
                            let allowed = try semantics.choices(for: row).map(\.rawValue).joined(separator: ",")
                            details.append("review=\(row.reason.rawValue),selected=\(row.decision.value?.choice.rawValue ?? "none"),source=\(localMatches),sourceDigest=\(row.local.sourceDigest == currentSourceDigest),sourceRevision=\(row.local.sourceRevision == String(source.snapshot.revision)),current=\(draft != nil),comparison=\(draft?.issueDigest == row.issueDigest),draftSelected=\(draft?.decision.value != nil),allowed=\(allowed),\(comparisons.joined(separator: ","))")
                        }
                    } catch {
                        let code = (error as? FailedEnableEvidenceError).map { String(describing: $0) }
                            ?? String(reflecting: type(of: error))
                        details.append("draftError=\(code)")
                    }
                }
                guard let candidateStore = self.store(id: transition.candidateStoreID) else {
                    throw SyncModePersistenceError.missingStore
                }
                let planRoot = self.storeURL(candidateStore)
                    .appendingPathComponent("full-reenable-v1", isDirectory: true)
                    .appendingPathComponent(transition.id.uuidString.lowercased(), isDirectory: true)
                let planURL = planRoot.appendingPathComponent("plan.json")
                if FileManager.default.fileExists(atPath: planURL.path) {
                    let plan = try JSONDecoder().decode(CloudFullReenableStagedPlan.self, from: Data(contentsOf: planURL))
                    let accepted = Dictionary(uniqueKeysWithValues: candidate.storage.readyEntities.map { ($0.reference, $0) })
                    let sameReferences = Set(plan.acceptedCAS.map { $0.accepted.reference }) == Set(accepted.keys)
                    let casMatches = plan.acceptedCAS.allSatisfy { expected in
                        accepted[expected.accepted.reference].map(CloudFullReenableAcceptedCAS.init) == expected
                    }
                    details += ["stagedPlan=true", "planCASReferences=\(sameReferences)", "planCASValues=\(casMatches)",
                        "planNamespaceRevision=\(plan.expectedNamespaceRevision == candidate.storage.namespaceState.revision)",
                        "planTargetRevision=\(plan.targetRevision == candidate.snapshot.revision)",
                        "planTargetDigest=\(plan.targetDigest == SnipLibraryTransferPlanner.digest(snapshot: candidate.snapshot))"]
                } else { details.append("stagedPlan=false") }
                return (details.joined(separator: "; "), transfer?.planDigest)
            }
            facts.append(checked.0.0)
            let candidate = checked.1
            let receipt = candidate.receipt
            let receiptMatches = receipt.map { FailedEnableEncoding.hex($0) == checked.0.1 } ?? false
            facts.append("stagedBatches=\(candidate.staged.count),withRaw=\(candidate.staged.filter { $0.rawBatchData != nil }.count)")
            let engine = candidate.engineState
            let checkpoint = try engine.map { try JSONDecoder().decode(CloudEngineStateEnvelope.self, from: $0) }
            facts += ["receipt=\(receipt != nil),matchesTransfer=\(receiptMatches)",
                "checkpoint=\(checkpoint != nil),initialFetch=\(String(describing: checkpoint?.requiresInitialFetch))",
                "manifestStable=\(manifest == before)"]
            return facts.joined(separator: "; ")
        } catch {
            let code = (error as? FailedEnableEvidenceError).map { String(describing: $0) }
                ?? String(reflecting: type(of: error))
            facts += ["factsError=\(code)", "manifestStable=\(manifest == before)"]
            return facts.joined(separator: "; ")
        }
    }

    fileprivate func withFailedEnableC72Read<Value: Sendable>(transition: SyncModeTransition,
        _ body: (FailedEnableStoreRead, FailedEnableStoreRead) throws -> Value
    ) throws -> (Value, FailedEnableC72StoreRead) {
        guard failedEnablePublicationInFlight == nil, fullReenableMergeInFlight == nil,
            failedEnableSendInFlight == nil, manifest.writeReservation == nil,
            manifest.transition == transition,
            let source = store(id: transition.sourceStoreID),
            let candidate = store(id: transition.candidateStoreID),
            let namespace = transition.namespace else { throw FailedEnableEvidenceError.changed }
        let before = manifest
        let sourceURL = storeFileURL(source)
        let candidateURL = storeFileURL(candidate)
        let locks = try FailedEnableReadLocks(stores: [
            (source.id, sourceURL.appendingPathExtension("lock")),
            (candidate.id, candidateURL.appendingPathExtension("lock"))])
        defer { withExtendedLifetime(locks) {} }
        let local = try FailedEnableC72StoreRead.read(storeURL: sourceURL, revision: source.revision,
            namespace: namespace, transitionID: nil, locks: locks)
        let remote = try FailedEnableC72StoreRead.read(storeURL: candidateURL, revision: candidate.revision,
            namespace: namespace, transitionID: transition.id, locks: locks)
        guard manifest == before else { throw FailedEnableEvidenceError.changed }
        return (try body(local.value, remote.value), remote)
    }
}

private extension SwiftDataSnipLibrary {
    func failedEnableC72ReceiptDigest(namespace: CloudSyncNamespaceKey, transitionID: UUID) throws -> Data? {
        guard let container else { throw SnipLibraryError.storeUnavailable }
        let lock = try SnipStoreFileLock(url: lockURL)
        defer { withExtendedLifetime(lock) {} }
        let context = Self.makeContext(container: container)
        let digest = try SwiftDataCloudFullOperationReceipts.digest(for: .reenableTransition(transitionID),
            namespaceKey: namespace.rawValue, context: context)
        try lock.check()
        return digest
    }
}

// Saves are disabled; the diagnostic never runs the library initializer or its backfills.
private struct FailedEnableC72StoreRead: Sendable {
    let value: FailedEnableStoreRead
    let receipt: Data?
    let staged: [CloudFullBatchCommit]
    let engineState: Data?
    let recoveryKinds: [String]

    static func read(storeURL: URL, revision: UInt64, namespace: ICloudSyncNamespaceBinding,
        transitionID: UUID?, locks: FailedEnableReadLocks
    ) throws -> Self {
        let lockURL = storeURL.appendingPathExtension("lock")
        try locks.require(lockURL)
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            throw SyncModePersistenceError.missingStore
        }
        let schema = Schema(versionedSchema: SnipSnapSchemaV9.self)
        let configuration = ModelConfiguration("SnipSnapLocal", schema: schema, url: storeURL,
            allowsSave: false, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = SwiftDataSnipLibrary.makeContext(container: container)
        let loaded = try SwiftDataSnipLibrary.load(context: context, seenRequestIDs: [])
        let snips = loaded.state.allSnips(sortMode: .manual)
        // These three failing fixtures have no attachments. Do not invent missing-byte evidence.
        guard !loaded.lists.isEmpty, snips.allSatisfy({ $0.attachments.isEmpty }) else {
            throw FailedEnableEvidenceError.unsupported
        }
        let metadata = try SwiftDataSnipLibrary.transferMetadata(context: context)
        let snapshot = SnipLibraryTransferSnapshot(revision: revision, snips: snips,
            lists: loaded.state.allLists(), attachmentData: [:],
            legacyManualPositions: metadata.legacyManualPositions,
            opaqueSyncStateDigest: metadata.opaqueSyncStateDigest,
            opaqueSyncStatePayload: metadata.opaqueSyncStatePayload,
            additionalSeenRequestIDs: loaded.state.seenRequestIDs)
        let key = namespace.namespaceKey.rawValue
        let entities = try context.fetch(FetchDescriptor<StoredCloudEntityRecord>())
            .filter { $0.namespaceKey == key }.map(SwiftDataSnipLibrary.entity(from:))
        let conflicts = try context.fetch(FetchDescriptor<StoredCloudFullConflict>())
            .filter { $0.namespaceKey == key }.map { record -> CloudStoredConflict in
                let prefix = "\(key)|conflict|"
                guard let kind = CloudEntityKind(rawValue: record.kind),
                    let format = CloudConflictFormat(rawValue: record.format), record.id.hasPrefix(prefix)
                else { throw SnipLibraryError.invalidStore }
                return CloudStoredConflict(key: String(record.id.dropFirst(prefix.count)),
                    reference: CloudEntityReference(kind: kind, domainID: record.domainID),
                    format: format, payload: record.payload)
            }
        let enrollment = try context.fetch(FetchDescriptor<StoredCloudFullEnrollment>())
            .first { $0.namespaceKey == key }
        let state = try SwiftDataSnipLibrary.fullEnrollmentState(from: enrollment?.referencesData)
        let deletes = try SwiftDataSnipLibrary.cloudPendingDeletes(namespaceKey: key, context: context).map {
            guard let value = $0.value else { throw SnipLibraryError.invalidStore }
            return value
        }
        let recoveries = try context.fetch(FetchDescriptor<StoredCloudRecoveryEvent>())
            .filter { $0.namespaceKey == key }.sorted { $0.eventKey < $1.eventKey }
        let kinds = try recoveries.filter { $0.eventKey.hasPrefix("full-recovery-") }.map { record in
            guard let envelope = CloudWirePayloadEnvelope.decode(record.payload), envelope.format == .fullRecordV1 else {
                throw CloudFullStorageError.invalidBatchReplay
            }
            let input = try JSONDecoder().decode(CloudFullRecoveryInput.self, from: envelope.payload)
            guard input.storageVersion == 1, input.namespaceKey == key,
                record.eventKey == "full-recovery-\(input.batchID.uuidString.lowercased())" else {
                throw CloudFullStorageError.invalidBatchReplay
            }
            return input.kind.rawValue
        }
        let staged = try context.fetch(FetchDescriptor<StoredCloudStagedBatch>())
            .filter { $0.namespaceKey == key }.compactMap { record -> CloudFullBatchCommit? in
                guard let envelope = CloudWirePayloadEnvelope.decode(record.payload), envelope.format == .fullRecordV1 else {
                    return nil
                }
                let batch = try JSONDecoder().decode(CloudFullBatchCommit.self, from: envelope.payload)
                guard batch.namespaceKey == key, batch.batchID == record.batchID, batch.storageVersion == 1 else {
                    throw CloudFullStorageError.invalidBatchReplay
                }
                return batch
            }
        let engine = try context.fetch(FetchDescriptor<StoredCloudEngineState>())
            .first { $0.namespaceKey == key }?.envelopeData
        let receipt = try transitionID.flatMap {
            try SwiftDataCloudFullOperationReceipts.digest(for: .reenableTransition($0),
                namespaceKey: key, context: context)
        }
        let read = FailedEnableStoreRead(snapshot: snapshot, seenRequestIDs: loaded.state.seenRequestIDs,
            storage: CloudFullStorageSnapshot(readyEntities: entities.filter { !$0.isDeferred },
                deferredEntities: entities.filter(\.isDeferred), pendingDeletes: deletes,
                conflicts: conflicts, enrolledEntities: state.references,
                quarantines: try SwiftDataSnipLibrary.quarantines(namespaceKey: key, context: context),
                namespaceState: state.namespaceState), recoveryDescriptors: recoveries.map(\.payload))
        guard !context.hasChanges else { throw FailedEnableEvidenceError.changed }
        try locks.require(lockURL)
        return Self(value: read, receipt: receipt, staged: staged, engineState: engine, recoveryKinds: kinds)
    }
}
