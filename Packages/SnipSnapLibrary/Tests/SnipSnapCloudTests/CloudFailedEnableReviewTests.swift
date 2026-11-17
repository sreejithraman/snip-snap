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
        let completedReceipt = try await rawCandidate.appliedFailedEnableReceiptDigest(
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
        let read = try await f.persistence.withFailedEnableComparisonRead(transition: transition) { ($0, $1) }
        let source = read.0
        let candidate = read.1
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
        let reread = try await f.persistence.withFailedEnableComparisonRead(transition: transition) { $1 }
        XCTAssertEqual(reread.storage, candidate.storage, "Pure comparisons cannot rewrite accepted CAS or archives")

        crash.arm(.beforePointerSwap)
        do {
            _ = try await f.mode.enableOrRetry()
            XCTFail("Expected the selected output interruption")
        } catch ReviewFixtureError.injected {}
        let interrupted = try await f.persistence.snapshot()
        let retry = try XCTUnwrap(interrupted.transition)
        let after = try await f.persistence.withFailedEnableComparisonRead(transition: retry) { ($0, $1) }
        let completed = try XCTUnwrap(try file.read(interrupted.activeStore.id))
        let applicable = try policy.reviewDrafts(FailedEnableReviewRead(source: after.0, candidate: after.1,
            transition: retry, evidence: completed))
        XCTAssertEqual(applicable.first(where: { $0.reference == row.reference })?.decision, row.decision)
        let completedGroup = try XCTUnwrap(completed.namespaces.first { $0.binding == FailedEnableBinding(f.namespace.binding) })
        let capture = try XCTUnwrap(completedGroup.captures.last { $0.candidateStoreID == FailedEnableEncoding.uuid(retry.candidateStoreID) })
        let originalObservation = try XCTUnwrap(capture.records.first { $0.reference == row.reference }?.unqualifiedObservation.value)
        let post = try XCTUnwrap(after.1.storage.readyEntities.first { $0.reference == reference })
        let postTyped = try CloudFullSyncPersistence.snipRecord(post)
        let postSnip = try XCTUnwrap(after.1.snapshot.snips.first { $0.id == f.snip.id })
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
        let drifted = comparisonCandidate(after.1, replacing: driftEntity)
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
            candidate: comparisonCandidate(after.1, replacing: reorderedPost), evidence: completed, requiresAccepted: true))
        XCTAssertThrowsError(try policy.validateExposure(capture: capture, candidate: drifted,
            evidence: completed, requiresAccepted: true))
        let driftedRows = try policy.reviewDrafts(FailedEnableReviewRead(source: after.0, candidate: drifted,
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

    func testCheckedTurnOffUnchangedDeletionRetainsEvidenceAcrossApplyAndPointerCrashes() async throws {
        for boundary in ["complete", "beforeApply", "afterApply", "beforePointer", "afterPointer",
                         "normalRetirement", "retirementReversion", "cleanupReversion"] {
            let crash = ReviewCrashSwitch()
            let f = try await fixture(crash: crash)
            defer { try? FileManager.default.removeItem(at: f.root) }
            let files = FailedEnableEvidenceFile(root: f.root)
            let initialManifest = await f.persistence.manifest
            let initialID = initialManifest.activeStoreID
            let initial = try await f.persistence.activeLibrary().checkedSnapshot(sortedBy: .manual)
            XCTAssertEqual(initial.snips, [f.snip])
            XCTAssertEqual(initial.lists, [SnipList.inbox])
            XCTAssertEqual(f.snip.content, "review fixture")
            XCTAssertEqual(f.snip.createdAt, Date(timeIntervalSince1970: 10))
            XCTAssertEqual(f.snip.updatedAt, Date(timeIntervalSince1970: 10))
            XCTAssertEqual(f.snip.origin, .quickEntry)
            XCTAssertNil(f.snip.source)
            XCTAssertFalse(f.snip.isDone)
            XCTAssertNil(f.snip.pinnedAt)
            XCTAssertTrue(f.snip.attachments.isEmpty)
            let firstOn = try await f.mode.enableOrRetry()
            XCTAssertEqual(firstOn.state, .on)
            let on = await f.persistence.manifest
            let cloud = try XCTUnwrap(on.stores.first { $0.id == on.activeStoreID })
            let cloudRaw = try await f.persistence.libraryForTransition(storeID: cloud.id)
            let actualA = try await cloudRaw.cloudFullStorageSnapshot(namespaceKey: f.namespace.namespaceKey)
            let snipRef = CloudEntityReference(kind: .snip, domainID: f.snip.id)
            let inboxRef = CloudEntityReference(kind: .list, domainID: SnipList.inbox.id)
            XCTAssertEqual(Set(actualA.readyEntities.map(\.reference)), Set([snipRef, inboxRef]))
            XCTAssertEqual(actualA.readyEntities.count, 2)
            let firstBundle = try XCTUnwrap(try files.read(initialID))
            let firstCapture = try XCTUnwrap(firstBundle.namespaces.flatMap(\.captures).last)
            let firstTransfer = try XCTUnwrap(firstBundle.transfers.last { $0.sourceCaptureIDs == [firstCapture.id] })
            XCTAssertEqual(firstTransfer.state, .checked)
            let expectedImages: [FailedEnableReference: FailedEnableImage] = [
                FailedEnableReference(snipRef): .snip(try FailedEnableSnipImage(f.snip, attachmentData: [:])),
                FailedEnableReference(inboxRef): .list(FailedEnableListImage(SnipList.inbox))
            ]
            let snipPresence: [String: FailedEnablePresence] = [
                "createdAt": .value, "id": .value, "isDone": .value, "originRaw": .value,
                "pinnedAt": .value, "placement": .value, "requestID": .value,
                "source": .value, "text": .value, "updatedAt": .value
            ]
            let listPresence: [String: FailedEnablePresence] = [
                "colorPreset": .value, "desiredName": .value, "id": .value,
                "orderKey": .value, "systemImage": .value, "updatedAt": .value
            ]
            XCTAssertEqual(Set(firstCapture.records.map(\.reference)), Set(expectedImages.keys))
            XCTAssertEqual(firstCapture.records.count, 2)
            for record in firstCapture.records {
                let reference = try record.reference.domain
                let row = try XCTUnwrap(actualA.readyEntities.first { $0.reference == reference })
                let observed = try XCTUnwrap(record.observedAccepted.value)
                let envelope = try JSONDecoder().decode(CloudAcceptedEntityInput.self, from: observed.entityBase64)
                XCTAssertEqual(record.source.value, expectedImages[record.reference])
                XCTAssertEqual(record.sourceMembership, .present)
                XCTAssertEqual(record.preparation.classification, .nonconflicting)
                XCTAssertEqual(record.preparation.baseKind, .noBaseEnrollment)
                XCTAssertEqual(record.preparation.normalizedLocal.acceptedPresence,
                               reference.kind == .snip ? snipPresence : listPresence)
                XCTAssertTrue(record.preparation.normalizedLocal.defaults.isEmpty)
                XCTAssertEqual(record.preparation.knownFields,
                    (reference.kind == .snip ? snipPresence : listPresence).keys.sorted())
                if reference.kind == .snip {
                    XCTAssertEqual(record.preparation.value.value, FailedEnablePreparedValue(
                        fields: .snip(FailedEnableSnipValue(id: FailedEnableEncoding.uuid(f.snip.id),
                            requestID: FailedEnableEncoding.uuid(f.snip.requestID),
                            createdAt: try FailedEnableEncoding.date(Date(timeIntervalSince1970: 10)),
                            originRaw: SnipOrigin.quickEntry.rawValue, text: "review fixture", source: .init(nil),
                            isDone: false, pinnedAt: .init(nil),
                            placement: FailedEnablePlacement(listID: FailedEnableEncoding.uuid(SnipList.inbox.id),
                                orderKey: f.snip.manualSortKey.data),
                            updatedAt: try FailedEnableEncoding.date(Date(timeIntervalSince1970: 10)))),
                        presence: snipPresence))
                } else {
                    XCTAssertEqual(record.preparation.value.value, FailedEnablePreparedValue(
                        fields: .list(FailedEnableListValue(id: FailedEnableEncoding.uuid(SnipList.inbox.id),
                            desiredName: SnipList.inbox.desiredName, systemImage: SnipList.inbox.systemImage,
                            colorPreset: .init(SnipList.inbox.color?.rawValue), orderKey: SnipList.inbox.sortKey.data,
                            updatedAt: "0000000000000000")), presence: listPresence))
                }
                XCTAssertEqual(observed.candidateStoreID, FailedEnableEncoding.uuid(cloud.id))
                XCTAssertEqual(observed.localRevision, String(row.localRevision))
                XCTAssertEqual(envelope.reference, row.reference)
                XCTAssertEqual(envelope.identity, row.identity)
                XCTAssertEqual(envelope.schemaVersion, 3)
                XCTAssertEqual(envelope.acceptedData, row.acceptedData)
                XCTAssertEqual(envelope.presenceData, row.presenceData)
                XCTAssertEqual(envelope.shadowData, row.shadowData)
                XCTAssertEqual(envelope.systemFields, row.systemFields)
                XCTAssertEqual(envelope.dependencyListID, row.dependencyListID)
                XCTAssertFalse(row.isDeferred)
                XCTAssertFalse(row.hasUnresolvedLegacyAbsence)
                XCTAssertNil(row.graphRepair)
                XCTAssertNil(record.unqualifiedObservation.value)
            }
            let firstSnipA = try XCTUnwrap(actualA.readyEntities.first { $0.reference == snipRef })
            let typedSnip = try JSONDecoder().decode(CloudTypedSnipRecord.self, from: firstSnipA.acceptedData)
            XCTAssertEqual(typedSnip, try JSONDecoder().decode(CloudTypedSnipRecord.self, from: firstSnipA.presenceData))
            XCTAssertEqual(typedSnip.id, .snip(f.snip.id, in: f.zone))
            XCTAssertEqual(typedSnip.domainID, f.snip.id)
            XCTAssertEqual(typedSnip.binding, .canonical)
            XCTAssertEqual(typedSnip.requestID, .value(f.snip.requestID))
            XCTAssertEqual(typedSnip.createdAt, .value(Date(timeIntervalSince1970: 10)))
            XCTAssertEqual(typedSnip.updatedAt, .value(Date(timeIntervalSince1970: 10)))
            XCTAssertEqual(typedSnip.text, .value("review fixture"))
            XCTAssertEqual(typedSnip.origin, .value(SnipOrigin.quickEntry.rawValue))
            XCTAssertEqual(typedSnip.source, .value(nil))
            XCTAssertEqual(typedSnip.isDone, .value(false))
            XCTAssertNil(typedSnip.pinnedAt)
            XCTAssertEqual(typedSnip.placement, .value(CloudSnipPlacement(
                listID: SnipList.inbox.id, orderKey: f.snip.manualSortKey)))
            XCTAssertEqual(firstSnipA.dependencyListID, SnipList.inbox.id)
            let firstListA = try XCTUnwrap(actualA.readyEntities.first { $0.reference == inboxRef })
            let typedList = try JSONDecoder().decode(CloudTypedListRecord.self, from: firstListA.acceptedData)
            guard case .value(let serverListDate) = typedList.updatedAt else {
                return XCTFail("The actual first committed list must supply its server-owned date")
            }
            let offResult = try await f.mode.optOut(.useCurrentCacheAfterStaleDataWarning)
            XCTAssertEqual(offResult.state, .off)
            let off = await f.persistence.manifest
            let sourceStore = try XCTUnwrap(off.stores.first { $0.id == off.activeStoreID })
            XCTAssertEqual(sourceStore.kind, .localOnly)
            let sourceRaw = try await f.persistence.libraryForTransition(storeID: sourceStore.id)
            let sourceBefore = try await sourceRaw.transferSnapshot(revision: sourceStore.revision)
            let dormantBefore = try await sourceRaw.dormantCloudBases()
            XCTAssertEqual(sourceBefore.snips, [f.snip])
            XCTAssertEqual(sourceBefore.lists, [SnipList.inbox])
            XCTAssertTrue(sourceBefore.attachmentData.isEmpty)
            let t0 = try XCTUnwrap(try files.read(sourceStore.id))
            let turnOff = try XCTUnwrap(t0.transfers.first { $0.kind == .turnOff })
            XCTAssertEqual(turnOff.state, .checked)
            XCTAssertEqual(turnOff.sourceStoreID, FailedEnableEncoding.uuid(cloud.id))
            XCTAssertEqual(turnOff.destinationStoreID, FailedEnableEncoding.uuid(sourceStore.id))
            XCTAssertEqual(turnOff.namespace, FailedEnableBinding(f.namespace.binding))
            for entry in try CloudDormantAcceptedBaseBundle.decode(sourceBefore.opaqueSyncStatePayload).entries {
                let row = try XCTUnwrap(actualA.readyEntities.first { $0.reference == entry.reference })
                let raw = try XCTUnwrap(dormantBefore.first { $0.reference == entry.reference })
                let envelope = try JSONDecoder().decode(CloudAcceptedEntityInput.self, from: entry.payload)
                XCTAssertEqual(raw.payload, entry.payload)
                XCTAssertEqual(envelope.acceptedData, row.acceptedData)
                XCTAssertEqual(envelope.presenceData, row.presenceData)
                XCTAssertEqual(envelope.shadowData, row.shadowData)
                XCTAssertEqual(envelope.systemFields, row.systemFields)
                XCTAssertEqual(envelope.identity, row.identity)
                XCTAssertEqual(envelope.schemaVersion, row.schemaVersion)
                XCTAssertEqual(envelope.dependencyListID, row.dependencyListID)
            }
            let recordID = CloudRecordID.snip(f.snip.id, in: f.zone)
            let serverBeforeValue = await f.server.fullSnapshot(for: recordID)
            let serverBefore = try XCTUnwrap(serverBeforeValue)
            let writer = FakeCloudRecordTransport(server: f.server, namespace: f.namespace)
            let deleted = try await writer.send(CloudOutboundBatch(operations: [
                .delete(recordID, base: serverBefore.shadow)
            ]))
            guard case .deleted(let deletedID) = try XCTUnwrap(deleted.items.first) else {
                return XCTFail("Expected the genuine checked original-record deletion")
            }
            XCTAssertEqual(deletedID, recordID)
            let serverAbsent = await f.server.fullSnapshot(for: recordID)
            XCTAssertNil(serverAbsent)

            let owner = Mutex<SwiftDataSyncModePersistence?>(nil)
            let saved = Mutex<[String: Data]>([:])
            let preparedIDs = Mutex<[UUID]>([])
            let reversionArmed = Mutex(false)
            let retirementHits = Mutex(0)
            let cleanupHits = Mutex(0)
            let p = try SwiftDataSyncModePersistence(rootURL: f.root, crashHook: { try crash.hit($0) },
                manifestWriter: { data, url in
                    try DurableFile.write(data, to: url)
                    let value = try JSONDecoder().decode(SwiftDataSyncModePersistence.Manifest.self, from: data)
                    if boundary == "cleanupReversion", value.transition?.phase == .recordsMerged,
                       value.transition?.sourceStoreID == sourceStore.id,
                       cleanupHits.withLock({ if $0 == 0 { $0 += 1; return true }; return false }) {
                        let checkpoint = try XCTUnwrap(saved.withLock { $0["prepared"] })
                        try DurableFile.write(checkpoint, to: files.url(sourceStore.id))
                    }
                }, writeHook: { point in
                    guard point == .beforeFullReenablePlanApply else { return }
                    let current = try XCTUnwrap(owner.withLock { $0 })
                    let m = await current.manifest
                    let transition = try XCTUnwrap(m.transition)
                    let intent = try XCTUnwrap(transition.mergeIntent)
                    let token = try XCTUnwrap(transition.freezeToken)
                    XCTAssertEqual(transition.phase, .sourceFrozen)
                    XCTAssertEqual(m.activeStoreID, sourceStore.id)
                    XCTAssertEqual(transition.sourceStoreID, sourceStore.id)
                    XCTAssertEqual(intent.fullReenablePlanID, transition.id)
                    XCTAssertEqual(intent.sourceRevision, sourceStore.revision)
                    XCTAssertEqual(token.revision, sourceStore.revision)
                    let bundle = try XCTUnwrap(try files.read(sourceStore.id))
                    let capture = try XCTUnwrap(bundle.namespaces.flatMap(\.captures).last)
                    let transfer = try XCTUnwrap(bundle.transfers.last { $0.sourceCaptureIDs == [capture.id] })
                    XCTAssertEqual(capture.transitionID, FailedEnableEncoding.uuid(transition.id))
                    XCTAssertEqual(capture.freeze.id, FailedEnableEncoding.uuid(token.id))
                    XCTAssertEqual(capture.sourceDigest, t0.continuity.sourceDigest)
                    XCTAssertEqual(transfer.state, .prepared)
                    XCTAssertEqual(transfer.planDigest, FailedEnableEncoding.hex(intent.planDigest))
                    XCTAssertEqual(transfer.outputs, [.list(FailedEnableListImage(SnipList.inbox))])
                    let q = try XCTUnwrap(capture.records.first { $0.reference == FailedEnableReference(snipRef) })
                    XCTAssertEqual(q.source.value, expectedImages[FailedEnableReference(snipRef)])
                    XCTAssertTrue(q.offlineChanged.isEmpty)
                    XCTAssertEqual(q.preparation.baseKind, .checkedTurnOff)
                    XCTAssertEqual(q.preparation.classification, .deleteRecovery)
                    XCTAssertEqual(q.preparation.value.value, FailedEnablePreparedValue(fields: .absent, presence: [:]))
                    XCTAssertNil(q.observedAccepted.value)
                    XCTAssertNil(q.unqualifiedObservation.value)
                    let listQ = try XCTUnwrap(capture.records.first { $0.reference == FailedEnableReference(inboxRef) })
                    XCTAssertEqual(listQ.preparation.value.value, FailedEnablePreparedValue(
                        fields: .list(FailedEnableListValue(id: FailedEnableEncoding.uuid(SnipList.inbox.id),
                            desiredName: SnipList.inbox.desiredName, systemImage: SnipList.inbox.systemImage,
                            colorPreset: .init(SnipList.inbox.color?.rawValue), orderKey: SnipList.inbox.sortKey.data,
                            updatedAt: try FailedEnableEncoding.date(serverListDate))), presence: listPresence))
                    let target = try XCTUnwrap(m.stores.first { $0.id == transition.candidateStoreID })
                    let retained = try XCTUnwrap(m.stores.first { $0.id == cloud.id })
                    XCTAssertEqual(Set([sourceStore.id, target.id, retained.id]).count, 3)
                    let localLibrary = try await current.libraryForTransition(storeID: sourceStore.id)
                    let targetLibrary = try await current.libraryForTransition(storeID: target.id)
                    let sourceURL = await current.storeFileURL(sourceStore)
                    let targetURL = await current.storeFileURL(target)
                    let retainedURL = await current.storeFileURL(retained)
                    let locks = try FailedEnableReadLocks(stores: [
                        (sourceStore.id, sourceURL.appendingPathExtension("lock")),
                        (target.id, targetURL.appendingPathExtension("lock")),
                        (retained.id, retainedURL.appendingPathExtension("lock"))
                    ])
                    defer { withExtendedLifetime(locks) {} }
                    let l = try await localLibrary.failedEnableRead(revision: sourceStore.revision,
                        namespace: f.namespace.binding, locks: locks)
                    let c = try await targetLibrary.failedEnableRead(revision: target.revision,
                        namespace: f.namespace.binding, locks: locks, reenableTransitionID: transition.id)
                    let old = try SwiftDataSnipLibrary.retainedFailedEnableRead(storeURL: retainedURL,
                        revision: retained.revision, namespace: f.namespace.binding, locks: locks)
                    XCTAssertEqual(l.snapshot, sourceBefore)
                    XCTAssertEqual(old.snapshot.snips, [f.snip])
                    XCTAssertTrue(c.snapshot.snips.isEmpty)
                    XCTAssertEqual(c.snapshot.lists, [SnipList.inbox])
                    XCTAssertEqual(c.storage.namespaceState.phase, .active)
                    let inventory = try XCTUnwrap(c.storage.namespaceState.initialFetchInventory)
                    XCTAssertTrue(inventory.canProveAbsence)
                    XCTAssertFalse(inventory.observed.contains(firstSnipA.identity))
                    XCTAssertTrue(inventory.observed.contains(firstListA.identity))
                    let engine = try JSONDecoder().decode(CloudEngineStateEnvelope.self,
                        from: try XCTUnwrap(c.engineState))
                    XCTAssertEqual(engine.namespace, f.namespace)
                    XCTAssertFalse(engine.requiresInitialFetch)
                    XCTAssertEqual(c.storage.readyEntities.map(\.reference), [inboxRef])
                    XCTAssertTrue(c.storage.deferredEntities.isEmpty)
                    XCTAssertTrue(c.storage.quarantines.isEmpty)
                    XCTAssertFalse(c.hasPendingBatches)
                    XCTAssertNil(c.reenableReceiptDigest)
                    let planURL = f.root.appendingPathComponent(target.relativeRoot)
                        .appendingPathComponent("full-reenable-v1")
                        .appendingPathComponent(transition.id.uuidString.lowercased())
                        .appendingPathComponent("plan.json")
                    let frameBytes = try Data(contentsOf: files.url(sourceStore.id))
                    let planBytes = try Data(contentsOf: planURL)
                    saved.withLock {
                        if $0["prepared"] == nil { $0["prepared"] = frameBytes; $0["plan"] = planBytes }
                    }
                    preparedIDs.withLock { $0 = [transition.id, target.id] }
                    if boundary == "beforeApply" { throw ReviewFixtureError.injected }
                }, afterMutationBeforeSave: {
                    guard reversionArmed.withLock({ if $0 { $0 = false; return true }; return false }) else { return }
                    let actual = try XCTUnwrap(try files.read(sourceStore.id))
                    let ids = preparedIDs.withLock { $0 }
                    let capture = try XCTUnwrap(actual.namespaces.flatMap(\.captures).last {
                        $0.transitionID == ids.first.map(FailedEnableEncoding.uuid)
                    })
                    let checked = try XCTUnwrap(actual.transfers.last { $0.sourceCaptureIDs == [capture.id] })
                    XCTAssertEqual(checked.state, .checked, "Recovery must really publish checked before the retirement hook")
                    let checkpoint = try XCTUnwrap(saved.withLock { $0["retirementPrepared"] })
                    try DurableFile.write(checkpoint, to: files.url(sourceStore.id))
                    let restored = try XCTUnwrap(try files.read(sourceStore.id))
                    let pending = try XCTUnwrap(restored.transfers.last { $0.sourceCaptureIDs == [capture.id] })
                    XCTAssertEqual(pending.state, .prepared)
                    XCTAssertEqual(pending.planDigest, checked.planDigest)
                    XCTAssertEqual(pending.outputs, checked.outputs)
                    retirementHits.withLock { $0 += 1 }
                })
            owner.withLock { $0 = p }
            let mode = coordinator(p, fixture: f)
            if ["afterApply", "normalRetirement", "retirementReversion"].contains(boundary) {
                crash.arm(.afterCandidateMergeDurability)
            } else if boundary == "beforePointer" {
                crash.arm(.beforePointerSwap)
            } else if boundary == "afterPointer" {
                crash.arm(.afterPointerSwap)
            }
            if boundary == "complete" {
                let result = try await mode.enableOrRetry()
                XCTAssertEqual(result.state, .on)
            } else if boundary == "cleanupReversion" {
                let result = try await mode.enableOrRetry()
                XCTAssertEqual(result.state, .needsAttention)
                XCTAssertEqual(cleanupHits.withLock { $0 }, 1)
            } else {
                do {
                    _ = try await mode.enableOrRetry()
                    XCTFail("Expected the actual \(boundary) interruption")
                } catch ReviewFixtureError.injected {}
            }
            let ids = preparedIDs.withLock { $0 }
            XCTAssertEqual(ids.count, 2)
            let transitionID = try XCTUnwrap(ids.first)
            let candidateID = try XCTUnwrap(ids.last)
            let candidate = try await p.libraryForTransition(storeID: candidateID)
            let currentStores = await p.manifest
            let candidateStore = try XCTUnwrap(currentStores.stores.first { $0.id == candidateID })
            let stagedURL = f.root.appendingPathComponent(candidateStore.relativeRoot)
                .appendingPathComponent("full-reenable-v1")
                .appendingPathComponent(transitionID.uuidString.lowercased())
                .appendingPathComponent("plan.json")
            if ["normalRetirement", "retirementReversion"].contains(boundary) {
                let before = await p.manifest
                let transition = try XCTUnwrap(before.transition)
                XCTAssertEqual(transition.phase, .sourceFrozen)
                let committed = try await candidate.appliedFailedEnableReceiptDigest(
                    namespace: f.namespace.namespaceKey, transitionID: transitionID)
                XCTAssertEqual(committed, transition.mergeIntent?.planDigest)
                XCTAssertNotNil(committed)
                try await p.unfreezeBeforePointerSwap(reason: .enrollmentBlocked)
                let ready = await p.manifest
                XCTAssertEqual(ready.transition?.phase, .candidateReady)
                let preparedBytes = try Data(contentsOf: files.url(sourceStore.id))
                saved.withLock { $0["retirementPrepared"] = preparedBytes }
                let recoveredBinding = try await p.recoverFailedEnableEvidence()
                let binding = try XCTUnwrap(recoveredBinding)
                XCTAssertEqual(binding.transfer.state, .prepared, "The returned binding must actually predate checked publication")
                let recovered = try XCTUnwrap(try files.read(sourceStore.id))
                XCTAssertEqual(recovered.transfers.last { $0.sourceCaptureIDs == [binding.capture.id] }?.state, .checked)
                reversionArmed.withLock { $0 = boundary == "retirementReversion" }
                do {
                    try await p.withFailedEnablePreparedReceipt(binding) { library, root in
                        try await library.retireFailedEnablePrepared(binding, evidenceRoot: root)
                    }
                    if boundary == "retirementReversion" { XCTFail("A restored prepared checkpoint cannot retire the real receipt") }
                } catch FailedEnableEvidenceError.changed {
                    XCTAssertEqual(boundary, "retirementReversion")
                }
                let receiptAfter = try await candidate.appliedFailedEnableReceiptDigest(
                    namespace: f.namespace.namespaceKey, transitionID: transitionID)
                if boundary == "retirementReversion" {
                    XCTAssertEqual(retirementHits.withLock { $0 }, 1)
                    XCTAssertEqual(receiptAfter, committed)
                    XCTAssertEqual(try Data(contentsOf: stagedURL), saved.withLock { $0["plan"] })
                    let retryValue = try await p.recoverFailedEnableEvidence()
                    let retryBinding = try XCTUnwrap(retryValue)
                    XCTAssertEqual(retryBinding.transfer.state, .prepared)
                    reversionArmed.withLock { $0 = true }
                    do {
                        try await p.withFailedEnablePreparedReceipt(retryBinding) { library, root in
                            try await library.retireFailedEnablePrepared(retryBinding, evidenceRoot: root)
                        }
                        XCTFail("Repeated retirement must refuse the same actual prepared checkpoint")
                    } catch FailedEnableEvidenceError.changed {}
                    XCTAssertEqual(retirementHits.withLock { $0 }, 2)
                    let retryReceipt = try await candidate.appliedFailedEnableReceiptDigest(
                        namespace: f.namespace.namespaceKey, transitionID: transitionID)
                    XCTAssertEqual(retryReceipt, committed)
                    let reopened = try SwiftDataSyncModePersistence(rootURL: f.root)
                    await reopened.installFailedEnableSemantics(
                        CloudFailedEnablePolicy(namespace: f.namespace, dataZone: f.zone),
                        accountCheck: { if case .available(let account) = await f.account.currentAccountState() {
                            return account == f.namespace.accountLineage
                        }; return false })
                    let retainedReceipt = try await reopened.libraryForTransition(storeID: candidateID)
                        .appliedFailedEnableReceiptDigest(namespace: f.namespace.namespaceKey, transitionID: transitionID)
                    XCTAssertEqual(retainedReceipt, committed)
                    let retained = try XCTUnwrap(try files.read(sourceStore.id))
                    XCTAssertEqual(retained.transfers.last { $0.sourceCaptureIDs == [binding.capture.id] }?.state, .prepared)
                    XCTAssertEqual(try Data(contentsOf: stagedURL), saved.withLock { $0["plan"] })
                    let writable = try await reopened.activeLibrary()
                    _ = try await writable.perform(.update(id: f.snip.id, content: "retirement refusal stays writable",
                        attachmentURLs: nil, expectedUpdatedAt: Date(timeIntervalSince1970: 10),
                        now: Date(timeIntervalSince1970: 90)), sortedBy: .manual)
                    let local = try await writable.checkedSnapshot(sortedBy: .manual)
                    XCTAssertEqual(local.snips.first?.content, "retirement refusal stays writable")
                    XCTAssertEqual(local.snips.first?.id, f.snip.id)
                    XCTAssertEqual(local.snips.first?.requestID, f.snip.requestID)
                    let originalStillAbsent = await f.server.fullSnapshot(for: recordID)
                    XCTAssertNil(originalStillAbsent)
                    continue
                }
                XCTAssertNil(receiptAfter)
            }
            if boundary == "cleanupReversion" {
                let stopped = await p.manifest
                XCTAssertEqual(stopped.activeStoreID, sourceStore.id)
                XCTAssertFalse(stopped.transition?.freezesSource == true)
                XCTAssertEqual(try Data(contentsOf: stagedURL), saved.withLock { $0["plan"] })
                let receipt = try await candidate.appliedFailedEnableReceiptDigest(
                    namespace: f.namespace.namespaceKey, transitionID: transitionID)
                XCTAssertNotNil(receipt)
                let source = try await p.activeLibrary()
                _ = try await source.perform(.update(id: f.snip.id, content: "cleanup refusal stays writable",
                    attachmentURLs: nil, expectedUpdatedAt: Date(timeIntervalSince1970: 10),
                    now: Date(timeIntervalSince1970: 90)), sortedBy: .manual)
                let local = try await source.checkedSnapshot(sortedBy: .manual)
                XCTAssertEqual(local.snips.first?.content, "cleanup refusal stays writable")
                XCTAssertEqual(local.snips.first?.requestID, f.snip.requestID)
                continue
            }
            let completing: SwiftDataSyncModePersistence
            let completingMode: ICloudSyncModeCoordinator
            if ["beforeApply", "afterApply", "beforePointer", "afterPointer"].contains(boundary) {
                completing = try SwiftDataSyncModePersistence(rootURL: f.root)
                completingMode = coordinator(completing, fixture: f)
            } else {
                completing = p
                completingMode = mode
            }
            let completed = try await completingMode.enableOrRetry()
            XCTAssertEqual(completed.state, .on, boundary)
            let activated = await completing.manifest
            XCTAssertNil(activated.transition)
            XCTAssertEqual(activated.activeStoreID, candidateID)
            XCTAssertNil(activated.attentionReason)
            let active = try await completing.activeLibrary()
            let final = try await active.checkedSnapshot(sortedBy: .manual)
            XCTAssertTrue(final.snips.isEmpty)
            XCTAssertEqual(final.lists, [SnipList.inbox])
            let activeRaw = try await completing.libraryForTransition(storeID: candidateID)
            let events = try await activeRaw.cloudFullRecoveryEvents(namespaceKey: f.namespace.namespaceKey)
            let archive = try await activeRaw.archive()
            XCTAssertTrue(events.isEmpty)
            XCTAssertTrue(archive.seenRequestIDs.isSubset(of: Set([f.snip.requestID])))
            let retainedSource = try await completing.libraryForTransition(storeID: sourceStore.id)
            let retainedSourceSnapshot = try await retainedSource.transferSnapshot(revision: sourceStore.revision)
            let retainedDormant = try await retainedSource.dormantCloudBases()
            XCTAssertEqual(retainedSourceSnapshot, sourceBefore)
            XCTAssertEqual(retainedDormant, dormantBefore)
            let retained = try XCTUnwrap(try files.read(sourceStore.id))
            XCTAssertTrue(retained.transfers.contains(turnOff))
            XCTAssertEqual(retained.blobs, t0.blobs)
            XCTAssertTrue(retained.namespaces.allSatisfy { $0.reviews.isEmpty && $0.alternatives.isEmpty })
            let originalBundle = try XCTUnwrap(try files.read(initialID))
            XCTAssertEqual(originalBundle.namespaces.flatMap(\.captures).first { $0.id == firstCapture.id }, firstCapture)
            XCTAssertTrue(originalBundle.transfers.contains(firstTransfer))
            let finalOriginal = await f.server.fullSnapshot(for: recordID)
            let finalTexts = await f.server.storedTextValues()
            let finalTypes = await f.server.storedRecordTypes(in: f.zone)
            let originalOperations = await f.server.acceptedOperationCount(for: recordID)
            let originalDeletes = await f.server.acceptedDeletionCount()
            XCTAssertNil(finalOriginal)
            XCTAssertEqual(finalTexts, [])
            XCTAssertEqual(finalTypes, ["List"])
            XCTAssertEqual(originalOperations, 2)
            XCTAssertEqual(originalDeletes, 1)
            let repeated = try await completingMode.enableOrRetry()
            XCTAssertEqual(repeated.state, .on)
            let repeatedManifest = await completing.manifest
            XCTAssertNil(repeatedManifest.transition)
            XCTAssertEqual(repeatedManifest.activeStoreID, candidateID)
            let reopened = try SwiftDataSyncModePersistence(rootURL: f.root)
            let reopenedMode = coordinator(reopened, fixture: f)
            let reopenedResult = try await reopenedMode.enableOrRetry()
            XCTAssertEqual(reopenedResult.state, .on)
            let reopenedContents = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
            XCTAssertTrue(reopenedContents.snips.isEmpty)
            XCTAssertEqual(reopenedContents.lists, [SnipList.inbox])
        }
    }

    func testCheckedTurnOffUnchangedDeletionRejectsMissingAuthorityAndChangedSource() async throws {
        for fault in ["ownership", "reservation", "epoch", "text", "done", "order", "bytes", "membership",
                      "account", "nilAccount", "registration", "namespace", "missingBundle", "missingCapture",
                      "afterApplyMissingBundle", "afterApplyMissingCapture", "missingRoot", "history",
                      "retainedMetadata", "lostEngine", "incremental", "failedInventory", "resetInventory",
                      "candidatePresent", "acceptedCAS", "operations"] {
            let crash = ReviewCrashSwitch()
            let f = try await fixture(crash: crash)
            defer { try? FileManager.default.removeItem(at: f.root) }
            let files = FailedEnableEvidenceFile(root: f.root)
            let initialManifest = await f.persistence.manifest
            let initialID = initialManifest.activeStoreID
            let first = try await f.persistence.activeLibrary().checkedSnapshot(sortedBy: .manual)
            XCTAssertEqual(first.snips, [f.snip])
            XCTAssertEqual(f.snip.content, "review fixture")
            XCTAssertEqual(f.snip.createdAt, Date(timeIntervalSince1970: 10))
            XCTAssertEqual(f.snip.updatedAt, Date(timeIntervalSince1970: 10))
            XCTAssertFalse(f.snip.isDone)
            XCTAssertEqual(f.snip.origin, .quickEntry)
            XCTAssertNil(f.snip.source)
            XCTAssertNil(f.snip.pinnedAt)
            XCTAssertTrue(f.snip.attachments.isEmpty)
            let on = try await f.mode.enableOrRetry()
            XCTAssertEqual(on.state, .on)
            let onManifest = await f.persistence.manifest
            let retainedStore = try XCTUnwrap(onManifest.stores.first { $0.id == onManifest.activeStoreID })
            let retainedLibrary = try await f.persistence.libraryForTransition(storeID: retainedStore.id)
            let firstA = try await retainedLibrary.cloudFullStorageSnapshot(namespaceKey: f.namespace.namespaceKey)
            let snipReference = CloudEntityReference(kind: .snip, domainID: f.snip.id)
            let inboxReference = CloudEntityReference(kind: .list, domainID: SnipList.inbox.id)
            let actualSnipA = try XCTUnwrap(firstA.readyEntities.first { $0.reference == snipReference })
            let actualInboxA = try XCTUnwrap(firstA.readyEntities.first { $0.reference == inboxReference })
            let firstFrame = try XCTUnwrap(try files.read(initialID))
            let firstCapture = try XCTUnwrap(firstFrame.namespaces.flatMap(\.captures).last)
            let originalRecord = CloudRecordID.snip(f.snip.id, in: f.zone)
            let writer = FakeCloudRecordTransport(server: f.server, namespace: f.namespace)
            if fault == "history" {
                var changed = f.snip
                changed.isDone = true
                changed.updatedAt = Date(timeIntervalSince1970: 20)
                let accepted = try JSONDecoder().decode(CloudTypedSnipRecord.self, from: actualSnipA.acceptedData)
                let save = try await writer.send(CloudOutboundBatch(operations: [
                    .save(try CloudFullRecordCodec.snipDraft(changed, accepted: accepted))
                ]))
                XCTAssertEqual(save.items.count, 1)
                let driver = CloudFullSyncCoordinator(store: CloudFullSyncPersistence(library: retainedLibrary,
                    namespace: f.namespace, dataZone: f.zone),
                    transport: FakeCloudRecordTransport(server: f.server, namespace: f.namespace))
                let lease = try await f.persistence.activeCloudMutationLease(storeID: retainedStore.id, purpose: .sync)
                _ = try await lease.run { try await driver.fetchRemote() }
                let current = try await f.persistence.activeLibrary().checkedSnapshot(sortedBy: .manual)
                XCTAssertEqual(current.snips.first?.id, f.snip.id)
                XCTAssertEqual(current.snips.first?.requestID, f.snip.requestID)
                XCTAssertEqual(current.snips.first?.content, "review fixture")
                XCTAssertEqual(current.snips.first?.isDone, true)
                let earlier = try XCTUnwrap(firstCapture.records.first {
                    $0.reference == FailedEnableReference(snipReference)
                })
                guard let earlierImage = earlier.source.value, case .snip(let image) = earlierImage else {
                    return XCTFail("The actual earlier frozen L must remain available")
                }
                XCTAssertFalse(image.isDone)
            }
            let offResult = try await f.mode.optOut(.useCurrentCacheAfterStaleDataWarning)
            XCTAssertEqual(offResult.state, .off)
            let off = await f.persistence.manifest
            let sourceStore = try XCTUnwrap(off.stores.first { $0.id == off.activeStoreID })
            let source = try await f.persistence.libraryForTransition(storeID: sourceStore.id)
            let sourceBefore = try await source.transferSnapshot(revision: sourceStore.revision)
            let dormantBefore = try await source.dormantCloudBases()
            let turnOffBytes = try Data(contentsOf: files.url(sourceStore.id))
            let turnOffFrame = try XCTUnwrap(try files.read(sourceStore.id))
            let t0 = try XCTUnwrap(turnOffFrame.transfers.first { $0.kind == .turnOff })
            XCTAssertEqual(t0.state, .checked)
            XCTAssertEqual(t0.sourceStoreID, FailedEnableEncoding.uuid(retainedStore.id))
            XCTAssertEqual(t0.destinationStoreID, FailedEnableEncoding.uuid(sourceStore.id))
            XCTAssertEqual(t0.namespace, FailedEnableBinding(f.namespace.binding))
            XCTAssertEqual(sourceBefore.snips.count, 1)
            XCTAssertEqual(sourceBefore.snips.first?.id, f.snip.id)
            XCTAssertEqual(sourceBefore.snips.first?.requestID, f.snip.requestID)
            XCTAssertEqual(sourceBefore.snips.first?.content, "review fixture")
            XCTAssertEqual(sourceBefore.snips.first?.isDone, fault == "history")
            XCTAssertTrue(sourceBefore.attachmentData.isEmpty)
            let dormant = try CloudDormantAcceptedBaseBundle.decode(sourceBefore.opaqueSyncStatePayload)
            XCTAssertEqual(Set(dormant.entries.map(\.reference)), Set([snipReference, inboxReference]))
            for entry in dormant.entries {
                let bytes = try XCTUnwrap(dormantBefore.first { $0.reference == entry.reference }?.payload)
                XCTAssertEqual(entry.payload, bytes)
                let a = try JSONDecoder().decode(CloudAcceptedEntityInput.self, from: bytes)
                let rows = try await retainedLibrary.cloudFullStorageSnapshot(namespaceKey: f.namespace.namespaceKey)
                let actual = try XCTUnwrap(rows.readyEntities.first { $0.reference == entry.reference })
                XCTAssertEqual(a.acceptedData, actual.acceptedData)
                XCTAssertEqual(a.presenceData, actual.presenceData)
                XCTAssertEqual(a.shadowData, actual.shadowData)
                XCTAssertEqual(a.systemFields, actual.systemFields)
                XCTAssertEqual(a.identity, actual.identity)
                XCTAssertEqual(a.schemaVersion, actual.schemaVersion)
                XCTAssertEqual(a.dependencyListID, actual.dependencyListID)
            }
            if fault == "retainedMetadata" {
                let inboxID = CloudRecordID.list(SnipList.inbox.id, in: f.zone)
                let priorValue = await f.server.fullSnapshot(for: inboxID)
                let prior = try XCTUnwrap(priorValue)
                let changed = CloudRecordDraft(id: inboxID, recordType: "List", schemaVersion: 3,
                    routingFields: [:], encryptedFields: ["retainedUnknown": .string("actual later retained value")],
                    base: prior.shadow)
                _ = try await writer.send(CloudOutboundBatch(operations: [.save(changed)]))
                let driver = CloudFullSyncCoordinator(store: CloudFullSyncPersistence(library: retainedLibrary,
                    namespace: f.namespace, dataZone: f.zone),
                    transport: FakeCloudRecordTransport(server: f.server, namespace: f.namespace))
                _ = try await driver.fetchRemote()
                let later = try await retainedLibrary.cloudFullStorageSnapshot(namespaceKey: f.namespace.namespaceKey)
                let laterInbox = try XCTUnwrap(later.readyEntities.first { $0.reference == inboxReference })
                XCTAssertNotEqual(laterInbox.acceptedData, actualInboxA.acceptedData)
                let retainedCore = try await retainedLibrary.checkedSnapshot(sortedBy: .manual)
                XCTAssertEqual(retainedCore.snips, [f.snip])
                XCTAssertEqual(try Data(contentsOf: files.url(sourceStore.id)), turnOffBytes)
            }
            let serverValue = await f.server.fullSnapshot(for: originalRecord)
            let serverOriginal = try XCTUnwrap(serverValue)
            let deletion = try await writer.send(CloudOutboundBatch(operations: [
                .delete(originalRecord, base: serverOriginal.shadow)
            ]))
            guard case .deleted(let identity) = try XCTUnwrap(deletion.items.first) else {
                return XCTFail("A real successful server delete is required")
            }
            XCTAssertEqual(identity, originalRecord)
            let absent = await f.server.fullSnapshot(for: originalRecord)
            XCTAssertNil(absent)

            let owner = Mutex<SwiftDataSyncModePersistence?>(nil)
            let reached = Mutex(false)
            let faultAtReplay = Mutex(false)
            let observed = Mutex<[String: Data]>([:])
            let enteredReservation = expectation(description: "The actual reservation is durable for \(fault)")
            let releaseReservation = AsyncStream<Void>.makeStream()
            let pauseReservation = Mutex(false)
            let p = try SwiftDataSyncModePersistence(rootURL: f.root, crashHook: { try crash.hit($0) },
                writeHook: { point in
                    if point == .afterRevisionReserved, pauseReservation.withLock({ $0 }) {
                        enteredReservation.fulfill()
                        for await _ in releaseReservation.stream { break }
                    }
                    guard point == .beforeFullReenablePlanApply else { return }
                    let current = try XCTUnwrap(owner.withLock { $0 })
                    let m = await current.manifest
                    let t = try XCTUnwrap(m.transition)
                    let capture = try XCTUnwrap(try files.read(sourceStore.id)?.namespaces.flatMap(\.captures).last {
                        $0.transitionID == FailedEnableEncoding.uuid(t.id)
                    })
                    XCTAssertEqual(t.mergeIntent?.fullReenablePlanID, t.id)
                    XCTAssertEqual(capture.freeze.id, t.freezeToken.map { FailedEnableEncoding.uuid($0.id) })
                    XCTAssertEqual(capture.sourceDigest, turnOffFrame.continuity.sourceDigest)
                    let candidate = try XCTUnwrap(m.stores.first { $0.id == t.candidateStoreID })
                    let planURL = f.root.appendingPathComponent(candidate.relativeRoot)
                        .appendingPathComponent("full-reenable-v1")
                        .appendingPathComponent(t.id.uuidString.lowercased()).appendingPathComponent("plan.json")
                    if reached.withLock({ let first = !$0; $0 = true; return first }) {
                        let frame = try Data(contentsOf: files.url(sourceStore.id))
                        let plan = try Data(contentsOf: planURL)
                        observed.withLock { $0["prepared"] = frame; $0["plan"] = plan }
                        if !fault.hasPrefix("afterApply") { throw ReviewFixtureError.injected }
                    } else if faultAtReplay.withLock({ $0 }) {
                        let savedURL = f.root.appendingPathComponent("retained-actual-prepared-frame")
                        if fault == "missingBundle" {
                            try FileManager.default.moveItem(at: files.url(sourceStore.id), to: savedURL)
                        } else if fault == "missingCapture" {
                            let original = try Data(contentsOf: files.url(sourceStore.id))
                            try DurableFile.write(original, to: savedURL)
                            try files.update(sourceStore.id) { value in
                                guard var value else { throw FailedEnableEvidenceError.changed }
                                for i in value.namespaces.indices {
                                    value.namespaces[i].captures.removeAll { $0.id == capture.id }
                                }
                                value.transfers.removeAll { $0.sourceCaptureIDs.contains(capture.id) }
                                return value
                            }
                        }
                    }
                })
            owner.withLock { $0 = p }
            let mode = coordinator(p, fixture: f)
            if fault.hasPrefix("afterApply") { crash.arm(.afterCandidateMergeDurability) }
            if ["history", "retainedMetadata"].contains(fault) {
                let refused = try await mode.enableOrRetry()
                XCTAssertEqual(refused.state, .needsAttention, fault)
                XCTAssertFalse(reached.withLock { $0 })
                let stopped = await p.manifest
                XCTAssertEqual(stopped.activeStoreID, sourceStore.id)
                XCTAssertFalse(stopped.transition?.freezesSource == true)
                let retained = try XCTUnwrap(try files.read(sourceStore.id))
                XCTAssertTrue(retained.transfers.contains(t0))
                let retainedFirst = try XCTUnwrap(try files.read(initialID))
                XCTAssertEqual(retainedFirst.namespaces.flatMap(\.captures).first { $0.id == firstCapture.id }, firstCapture)
                let unchanged = try await source.transferSnapshot(revision: sourceStore.revision)
                XCTAssertEqual(unchanged, sourceBefore)
                let stillAbsent = await f.server.fullSnapshot(for: originalRecord)
                XCTAssertNil(stillAbsent)
                continue
            }
            do {
                _ = try await mode.enableOrRetry()
                XCTFail("Expected the real prepared-operation interruption for \(fault)")
            } catch ReviewFixtureError.injected {}
            XCTAssertTrue(reached.withLock { $0 })
            let preimage = await p.manifest
            let transition = try XCTUnwrap(preimage.transition)
            let intent = try XCTUnwrap(transition.mergeIntent)
            let token = try XCTUnwrap(transition.freezeToken)
            XCTAssertEqual(transition.phase, .sourceFrozen)
            let candidateStore = try XCTUnwrap(preimage.stores.first { $0.id == transition.candidateStoreID })
            let candidate = try await p.libraryForTransition(storeID: candidateStore.id)
            let raw = CloudFullSyncPersistence(library: candidate, namespace: f.namespace, dataZone: f.zone)
            let preparationValue = try await p.failedEnablePreparedRead(transition: transition,
                digest: intent.planDigest, token: token)
            let preparation = try XCTUnwrap(preparationValue)
            XCTAssertTrue(preparation.requiresTurnOffAbsence)
            XCTAssertEqual(preparation.transfer.state, .prepared)
            let stagedRoot = f.root.appendingPathComponent(candidateStore.relativeRoot)
                .appendingPathComponent("full-reenable-v1")
                .appendingPathComponent(transition.id.uuidString.lowercased())
            let stagedEnvelope = try JSONDecoder().decode(CloudFullReenableStagedPlan.self,
                from: Data(contentsOf: stagedRoot.appendingPathComponent("plan.json")))
            let staged = try stagedEnvelope.restore(from: stagedRoot)
            XCTAssertEqual(staged.plan.planDigest, intent.planDigest)
            XCTAssertEqual(staged.plan.snips, [])
            XCTAssertEqual(staged.plan.result.approvedSnipIDs, [])
            let registration = await p.failedEnableSemanticRegistration
            let receiptBefore = try await candidate.appliedFailedEnableReceiptDigest(
                namespace: f.namespace.namespaceKey, transitionID: transition.id)
            XCTAssertEqual(receiptBefore != nil, fault.hasPrefix("afterApply"))
            let candidateBefore = try await candidate.transferSnapshot(revision: candidateStore.revision)
            XCTAssertTrue(candidateBefore.snips.isEmpty)
            let eventsBefore = await f.transports.events()
            let frameBefore = try Data(contentsOf: files.url(sourceStore.id))
            var expectedRegistration = registration
            if fault == "ownership" {
                try await p.beginStoreReplacement()
                let denied = try await p.validateFailedEnableTurnOffApply(transition: transition,
                    preparation: preparation, digest: intent.planDigest, applied: false,
                    expectedManifest: preimage, expectedRegistration: registration)
                XCTAssertFalse(denied)
                await p.finishStoreReplacement()
                let entered = expectation(description: "The account callback observes the actual owned three-root publication")
                let release = AsyncStream<Void>.makeStream()
                let calls = Mutex(0)
                await p.installFailedEnableSemantics(CloudFailedEnablePolicy(namespace: f.namespace, dataZone: f.zone),
                    accountCheck: {
                        let n = calls.withLock { $0 += 1; return $0 }
                        if n == 2 {
                            entered.fulfill()
                            for await _ in release.stream { break }
                        }
                        guard case .available(let account) = await f.account.currentAccountState() else { return false }
                        return account == f.namespace.accountLineage
                    })
                let newRegistration = await p.failedEnableSemanticRegistration
                let held = Task {
                    try await p.validateFailedEnableTurnOffApply(transition: transition, preparation: preparation,
                        digest: intent.planDigest, applied: false, expectedManifest: preimage,
                        expectedRegistration: newRegistration)
                }
                await fulfillment(of: [entered], timeout: 30)
                let publication = await p.failedEnablePublicationInFlight
                let blocked = await p.writeAdmissionIsIdle()
                let whileHeld = await p.manifest
                XCTAssertEqual(publication, transition.id)
                XCTAssertFalse(blocked)
                XCTAssertEqual(whileHeld, preimage)
                XCTAssertNil(whileHeld.writeReservation)
                do {
                    try await p.beginStoreReplacement()
                    XCTFail("Another admitted owner must not enter the held publication")
                } catch SyncModePersistenceError.transitionInProgress {}
                release.continuation.yield(())
                let admitted = try await held.value
                XCTAssertTrue(admitted, "The actual owned idle phase must pass with all three real roots")
                let released = await p.failedEnablePublicationInFlight
                XCTAssertNil(released)
                let completed = try await mode.enableOrRetry()
                XCTAssertEqual(completed.state, .on)
                let final = try await p.activeLibrary().checkedSnapshot(sortedBy: .manual)
                XCTAssertTrue(final.snips.isEmpty)
                let finalManifest = await p.manifest
                XCTAssertNil(finalManifest.transition)
                continue
            } else if ["epoch", "text", "done", "order", "bytes", "membership", "reservation"].contains(fault) {
                try await p.unfreezeBeforePointerSwap(reason: .enrollmentBlocked)
                let local = try await p.activeLibrary()
                if fault == "text" {
                    _ = try await local.perform(.update(id: f.snip.id, content: "independent later text",
                        attachmentURLs: nil, expectedUpdatedAt: Date(timeIntervalSince1970: 10),
                        now: Date(timeIntervalSince1970: 50)), sortedBy: .manual)
                } else if fault == "done" {
                    _ = try await local.perform(.setDone(ids: [f.snip.id], done: true), sortedBy: .manual)
                } else if fault == "order" {
                    var changed = f.snip
                    changed.manualSortKey = SnipOrderKey(rawDigits: [64])
                    _ = try await local.perform(.replaceAll([changed]), sortedBy: .manual)
                } else if fault == "bytes" {
                    let url = f.root.appendingPathComponent("independent-later-bytes.txt")
                    try Data("independent later attachment".utf8).write(to: url)
                    _ = try await local.perform(.update(id: f.snip.id, content: "review fixture",
                        attachmentURLs: [url], expectedUpdatedAt: Date(timeIntervalSince1970: 10),
                        now: Date(timeIntervalSince1970: 50)), sortedBy: .manual)
                } else if fault == "membership" {
                    _ = try await local.perform(.add(content: "independent additional member", origin: .quickEntry,
                        source: nil, listID: SnipList.inbox.id, attachmentURLs: [], requestID: UUID(),
                        now: Date(timeIntervalSince1970: 50)), sortedBy: .manual)
                } else if fault == "reservation" {
                    pauseReservation.withLock { $0 = true }
                    let write = Task {
                        try await local.perform(.update(id: f.snip.id, content: "reserved independent edit",
                            attachmentURLs: nil, expectedUpdatedAt: Date(timeIntervalSince1970: 10),
                            now: Date(timeIntervalSince1970: 50)), sortedBy: .manual)
                    }
                    await fulfillment(of: [enteredReservation], timeout: 30)
                    let reserved = await p.manifest
                    XCTAssertNotNil(reserved.writeReservation)
                    let denied = try await p.validateFailedEnableTurnOffApply(transition: transition,
                        preparation: preparation, digest: intent.planDigest, applied: false,
                        expectedManifest: preimage, expectedRegistration: registration)
                    XCTAssertFalse(denied)
                    releaseReservation.continuation.yield(())
                    _ = try await write.value
                }
                let changedManifest = await p.manifest
                XCTAssertNotEqual(changedManifest, preimage)
                let changed = try await local.checkedSnapshot(sortedBy: .manual)
                XCTAssertTrue(changed.snips.contains { $0.id == f.snip.id && $0.requestID == f.snip.requestID })
                if fault == "text" { XCTAssertEqual(changed.snips.first?.content, "independent later text") }
                if fault == "done" { XCTAssertEqual(changed.snips.first?.isDone, true) }
                if fault == "order" { XCTAssertEqual(changed.snips.first?.manualSortKey.data, Data([64])) }
                if fault == "bytes" {
                    XCTAssertEqual(changed.snips.first?.attachments.count, 1)
                    let activeStore = try XCTUnwrap(changedManifest.stores.first { $0.id == changedManifest.activeStoreID })
                    let current = try await source.transferSnapshot(revision: activeStore.revision)
                    XCTAssertEqual(Set(current.attachmentData.values), Set([Data("independent later attachment".utf8)]))
                }
                if fault == "membership" {
                    XCTAssertEqual(Set(changed.snips.map(\.content)), Set(["review fixture", "independent additional member"]))
                }
            } else if fault == "account" {
                await f.account.set(.available(accountLineage: "another-account"))
            } else if fault == "nilAccount" {
                await p.installFailedEnableSemantics(CloudFailedEnablePolicy(namespace: f.namespace, dataZone: f.zone))
                expectedRegistration = await p.failedEnableSemanticRegistration
            } else if fault == "registration" {
                await p.installFailedEnableSemantics(CloudFailedEnablePolicy(namespace: f.namespace, dataZone: f.zone),
                    accountCheck: {
                        guard case .available(let account) = await f.account.currentAccountState() else { return false }
                        return account == f.namespace.accountLineage
                    })
                let newRegistration = await p.failedEnableSemanticRegistration
                XCTAssertNotEqual(newRegistration, registration)
            } else if fault == "namespace" {
                let other = CloudSyncNamespace(cloudScope: f.namespace.cloudScope, accountLineage: f.namespace.accountLineage,
                    generation: UUID(), zones: f.namespace.zones)
                await p.installFailedEnableSemantics(CloudFailedEnablePolicy(namespace: other, dataZone: f.zone),
                    accountCheck: {
                        guard case .available(let account) = await f.account.currentAccountState() else { return false }
                        return account == f.namespace.accountLineage
                    })
                expectedRegistration = await p.failedEnableSemanticRegistration
            } else if ["missingBundle", "missingCapture"].contains(fault) {
                faultAtReplay.withLock { $0 = true }
                try await p.reconcileFullReenableIntent()
                let savedURL = f.root.appendingPathComponent("retained-actual-prepared-frame")
                XCTAssertEqual(try Data(contentsOf: savedURL), frameBefore)
                if fault == "missingBundle" {
                    XCTAssertNil(try files.read(sourceStore.id))
                } else {
                    let remaining = try XCTUnwrap(try files.read(sourceStore.id))
                    XCTAssertFalse(remaining.namespaces.flatMap(\.captures).contains { $0.id == preparation.capture.id })
                    XCTAssertTrue(remaining.transfers.contains(t0))
                }
            } else if fault.hasPrefix("afterApply") {
                let savedURL = f.root.appendingPathComponent("retained-actual-prepared-frame")
                if fault == "afterApplyMissingBundle" {
                    try FileManager.default.moveItem(at: files.url(sourceStore.id), to: savedURL)
                } else {
                    try DurableFile.write(frameBefore, to: savedURL)
                    try files.update(sourceStore.id) { value in
                        guard var value else { throw FailedEnableEvidenceError.changed }
                        for i in value.namespaces.indices {
                            value.namespaces[i].captures.removeAll { $0.id == preparation.capture.id }
                        }
                        value.transfers.removeAll { $0.sourceCaptureIDs.contains(preparation.capture.id) }
                        return value
                    }
                }
                try await p.reconcileFullReenableIntent()
                XCTAssertEqual(try Data(contentsOf: savedURL), frameBefore)
            } else if fault == "missingRoot" {
                let rootURL = await p.storeFileURL(retainedStore)
                let held = rootURL.appendingPathExtension("retained-evidence")
                try FileManager.default.moveItem(at: rootURL, to: held)
                XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
            } else if fault == "lostEngine" {
                try await raw.clearEngineState()
                let engine = try await raw.loadEngineState()
                XCTAssertNil(engine)
            } else if fault == "incremental" {
                let driver = CloudFullSyncCoordinator(store: raw,
                    transport: FakeCloudRecordTransport(server: f.server, namespace: f.namespace))
                _ = try await driver.fetchRemote()
                let storage = try await candidate.cloudFullStorageSnapshot(namespaceKey: f.namespace.namespaceKey)
                XCTAssertFalse(storage.namespaceState.initialFetchInventory?.canProveAbsence == true)
            } else if fault == "failedInventory" {
                let transport = FakeCloudRecordTransport(server: f.server, namespace: f.namespace)
                let driver = CloudFullSyncCoordinator(store: raw, transport: transport)
                try await driver.prepareManualRetry(forceInitialInventory: true)
                await transport.failNextFetchedItem(.list(SnipList.inbox.id, in: f.zone), failure: .retryable)
                _ = try await driver.fetchRemote()
                let storage = try await candidate.cloudFullStorageSnapshot(namespaceKey: f.namespace.namespaceKey)
                XCTAssertFalse(storage.namespaceState.initialFetchInventory?.canProveAbsence == true)
            } else if fault == "resetInventory" {
                try await raw.prepareInitialFetch()
                let storage = try await candidate.cloudFullStorageSnapshot(namespaceKey: f.namespace.namespaceKey)
                XCTAssertTrue(storage.namespaceState.initialFetchInventory?.observed.isEmpty == true)
                let engine = try await raw.loadEngineState()
                XCTAssertNil(engine)
            } else if fault == "candidatePresent" {
                _ = try await candidate.perform(.replaceAll([f.snip]), sortedBy: .manual)
                let present = try await candidate.checkedSnapshot(sortedBy: .manual)
                XCTAssertEqual(present.snips, [f.snip])
                let storage = try await candidate.cloudFullStorageSnapshot(namespaceKey: f.namespace.namespaceKey)
                XCTAssertFalse(storage.readyEntities.contains { $0.reference == snipReference })
            } else if fault == "acceptedCAS" {
                let targetOnly = Snip(id: UUID(), requestID: UUID(), createdAt: Date(timeIntervalSince1970: 60),
                    updatedAt: Date(timeIntervalSince1970: 60), content: "actual unrelated deferred row",
                    origin: .quickEntry, source: nil, listID: UUID(), isDone: false,
                    manualSortKey: SnipOrderKey(rawDigits: [64]), attachments: [])
                _ = try await writer.send(CloudOutboundBatch(operations: [
                    .save(try CloudFullRecordCodec.snipDraft(targetOnly, in: f.zone))
                ]))
                let driver = CloudFullSyncCoordinator(store: raw,
                    transport: FakeCloudRecordTransport(server: f.server, namespace: f.namespace))
                _ = try await driver.fetchRemote()
                let storage = try await candidate.cloudFullStorageSnapshot(namespaceKey: f.namespace.namespaceKey)
                XCTAssertEqual(storage.deferredEntities.map(\.reference), [
                    CloudEntityReference(kind: .snip, domainID: targetOnly.id)
                ])
                let current = try await candidate.transferSnapshot(revision: candidateStore.revision)
                XCTAssertEqual(SnipLibraryTransferPlanner.digest(snapshot: current), staged.plan.targetDigest)
                do {
                    _ = try await candidate.applyCloudFullReenablePlan(staged.plan, currentRevision: candidateStore.revision)
                    XCTFail("The real namespace CAS must reject the stale plan")
                } catch CloudFullStorageError.namespaceStateMismatch {}
                let staleSet = try CloudFullReenableApplyPlan(transitionID: staged.plan.transitionID,
                    namespaceKey: staged.plan.namespaceKey, expectedNamespaceRevision: storage.namespaceState.revision,
                    targetRevision: staged.plan.targetRevision, targetDigest: staged.plan.targetDigest,
                    snips: staged.plan.snips, lists: staged.plan.lists, attachmentData: staged.plan.attachmentData,
                    dormantPayload: staged.plan.dormantPayload, acceptedCAS: staged.plan.acceptedCAS,
                    conflicts: staged.plan.conflicts, recoveryInputs: staged.plan.recoveryInputs, result: staged.plan.result)
                do {
                    _ = try await candidate.applyCloudFullReenablePlan(staleSet, currentRevision: candidateStore.revision)
                    XCTFail("A negative-only reconstructed plan cannot bypass the actual whole accepted-set CAS")
                } catch CloudFullStorageError.staleAcceptedEntity {}
            } else if fault == "operations" {
                try await p.reconcileFullReenableIntent()
                let merged = await p.manifest
                XCTAssertEqual(merged.transition?.phase, .recordsMerged)
                try await raw.approveModeMerge(snipIDs: [])
                try await p.recordEnrollmentApproved(expected: [])
                try await p.recordFirstSendStarted()
                let beforeAttempt = await p.manifest
                let captureBefore = try Data(contentsOf: files.url(sourceStore.id))
                let attempts = [
                    SyncModeSendOperation(reference: snipReference, recordIdentity: actualSnipA.identity, kind: .save),
                    SyncModeSendOperation(reference: snipReference, recordIdentity: actualSnipA.identity, kind: .delete),
                    SyncModeSendOperation(reference: nil, recordIdentity: actualSnipA.identity, kind: .save),
                    SyncModeSendOperation(reference: nil, recordIdentity: actualSnipA.identity, kind: .delete)
                ]
                for operation in attempts {
                    do {
                        try await p.recordSendAttempt(SyncModeSendAttempt(namespace: f.namespace.binding,
                            operations: [operation]))
                        XCTFail("The absent original cannot be saved or deleted by typed reference or canonical identity")
                    } catch FailedEnableEvidenceError.reviewRequired {}
                    let afterAttempt = await p.manifest
                    XCTAssertEqual(afterAttempt, beforeAttempt)
                    XCTAssertEqual(try Data(contentsOf: files.url(sourceStore.id)), captureBefore)
                    let attemptedEvents = await f.transports.events()
                    XCTAssertEqual(attemptedEvents, eventsBefore)
                }
                let completed = try await mode.enableOrRetry()
                XCTAssertEqual(completed.state, .on)
                let final = try await p.activeLibrary().checkedSnapshot(sortedBy: .manual)
                XCTAssertTrue(final.snips.isEmpty)
                let completedManifest = await p.manifest
                XCTAssertNil(completedManifest.transition)
                continue
            }
            let sourceBeforeRefusalManifest = await p.manifest
            let sourceBeforeRefusal = try await source.transferSnapshot(
                revision: try XCTUnwrap(sourceBeforeRefusalManifest.stores.first { $0.id == sourceStore.id }).revision)
            let candidateBeforeRefusal = try await candidate.transferSnapshot(revision: candidateStore.revision)
            let denied = try await p.validateFailedEnableTurnOffApply(transition: transition,
                preparation: preparation, digest: intent.planDigest, applied: false,
                expectedManifest: preimage, expectedRegistration: expectedRegistration)
            XCTAssertFalse(denied, fault)
            let afterRefusal = await p.manifest
            XCTAssertEqual(afterRefusal, sourceBeforeRefusalManifest)
            XCTAssertEqual(afterRefusal.activeStoreID, sourceStore.id)
            let sourceAfter = try await source.transferSnapshot(
                revision: try XCTUnwrap(afterRefusal.stores.first { $0.id == sourceStore.id }).revision)
            XCTAssertEqual(sourceAfter, sourceBeforeRefusal)
            let candidateAfter = try await candidate.transferSnapshot(revision: candidateStore.revision)
            XCTAssertEqual(candidateAfter, candidateBeforeRefusal)
            let receiptAfter = try await candidate.appliedFailedEnableReceiptDigest(
                namespace: f.namespace.namespaceKey, transitionID: transition.id)
            XCTAssertEqual(receiptAfter, receiptBefore)
            XCTAssertEqual(try Data(contentsOf: stagedRoot.appendingPathComponent("plan.json")), observed.withLock { $0["plan"] })
            let afterEvents = await f.transports.events()
            XCTAssertEqual(afterEvents, eventsBefore)
            let originalAfter = await f.server.fullSnapshot(for: originalRecord)
            XCTAssertNil(originalAfter)
            let savedFirst = try XCTUnwrap(try files.read(initialID))
            XCTAssertEqual(savedFirst.namespaces.flatMap(\.captures).first { $0.id == firstCapture.id }, firstCapture)
            let retainedDormant = try await source.dormantCloudBases()
            XCTAssertEqual(retainedDormant, dormantBefore)
            if transition.id == afterRefusal.transition?.id, afterRefusal.transition?.freezesSource == true {
                try await p.unfreezeBeforePointerSwap(reason: .enrollmentBlocked)
            }
            let writableManifest = await p.manifest
            XCTAssertFalse(writableManifest.transition?.freezesSource == true)
            let writable = try await p.activeLibrary()
            let localRequest = UUID()
            _ = try await writable.perform(.add(content: "local editing remains available after refusal",
                origin: .quickEntry, source: nil, listID: SnipList.inbox.id, attachmentURLs: [],
                requestID: localRequest, now: Date(timeIntervalSince1970: 80)), sortedBy: .manual)
            let edited = try await writable.checkedSnapshot(sortedBy: .manual)
            XCTAssertEqual(edited.snips.filter { $0.requestID == localRequest }.map(\.content),
                ["local editing remains available after refusal"])
            XCTAssertTrue(edited.snips.contains { $0.id == f.snip.id && $0.requestID == f.snip.requestID })
            if ["missingBundle", "missingCapture", "afterApplyMissingBundle", "afterApplyMissingCapture"].contains(fault) {
                let reopened = try SwiftDataSyncModePersistence(rootURL: f.root)
                let retainedCandidate = try await reopened.libraryForTransition(storeID: candidateStore.id)
                let reopenedReceipt = try await retainedCandidate.appliedFailedEnableReceiptDigest(
                    namespace: f.namespace.namespaceKey, transitionID: transition.id)
                XCTAssertEqual(reopenedReceipt, receiptBefore)
                XCTAssertEqual(try Data(contentsOf: stagedRoot.appendingPathComponent("plan.json")), observed.withLock { $0["plan"] })
                let reopenedManifest = await reopened.manifest
                XCTAssertEqual(reopenedManifest.activeStoreID, sourceStore.id)
                XCTAssertFalse(reopenedManifest.transition?.freezesSource == true)
            }
        }
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

extension SwiftDataSyncModePersistence {
    fileprivate func withFailedEnableComparisonRead<Value: Sendable>(transition: SyncModeTransition,
        _ body: (FailedEnableStoreRead, FailedEnableStoreRead) throws -> Value
    ) throws -> Value {
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
        let local = try FailedEnableComparisonStoreRead.read(storeURL: sourceURL, revision: source.revision,
            namespace: namespace, locks: locks)
        let remote = try FailedEnableComparisonStoreRead.read(storeURL: candidateURL, revision: candidate.revision,
            namespace: namespace, locks: locks)
        guard manifest == before else { throw FailedEnableEvidenceError.changed }
        return try body(local.value, remote.value)
    }
}

private extension SwiftDataSnipLibrary {
    func appliedFailedEnableReceiptDigest(namespace: CloudSyncNamespaceKey, transitionID: UUID) throws -> Data? {
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

// Saves are disabled; comparison reads never run the library initializer or its backfills.
private struct FailedEnableComparisonStoreRead: Sendable {
    let value: FailedEnableStoreRead

    static func read(storeURL: URL, revision: UInt64, namespace: ICloudSyncNamespaceBinding,
        locks: FailedEnableReadLocks
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
        // This comparison fixture excludes attachment-byte loading.
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
        for record in recoveries where record.eventKey.hasPrefix("full-recovery-") {
            guard let envelope = CloudWirePayloadEnvelope.decode(record.payload), envelope.format == .fullRecordV1 else {
                throw CloudFullStorageError.invalidBatchReplay
            }
            let input = try JSONDecoder().decode(CloudFullRecoveryInput.self, from: envelope.payload)
            guard input.storageVersion == 1, input.namespaceKey == key,
                record.eventKey == "full-recovery-\(input.batchID.uuidString.lowercased())" else {
                throw CloudFullStorageError.invalidBatchReplay
            }
        }
        let read = FailedEnableStoreRead(snapshot: snapshot, seenRequestIDs: loaded.state.seenRequestIDs,
            storage: CloudFullStorageSnapshot(readyEntities: entities.filter { !$0.isDeferred },
                deferredEntities: entities.filter(\.isDeferred), pendingDeletes: deletes,
                conflicts: conflicts, enrolledEntities: state.references,
                quarantines: try SwiftDataSnipLibrary.quarantines(namespaceKey: key, context: context),
                namespaceState: state.namespaceState), recoveryDescriptors: recoveries.map(\.payload))
        guard !context.hasChanges else { throw FailedEnableEvidenceError.changed }
        try locks.require(lockURL)
        return Self(value: read)
    }
}
