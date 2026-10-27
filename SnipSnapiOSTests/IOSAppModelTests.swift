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
final class IOSAppModelTests: IOSModelTestCase {
    func testCreateFailureNamesAddWithoutRecordingDraftText() async {
        let diagnostics = IOSDiagnosticRecorderProbe()
        let model = IOSAppModel(library: JSONSnipLibrary.unavailable(), diagnostics: diagnostics.recorder)

        let saved = await model.createSnip(content: "Private draft text", in: SnipList.inboxID)

        XCTAssertFalse(saved)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(diagnostics.events.count, 1)
        XCTAssertEqual(diagnostics.events.first?.operation, "snip.add")
        XCTAssertEqual(diagnostics.events.first?.errorCode, "library.storeUnavailable")
        XCTAssertFalse(diagnostics.events.first?.line.contains("Private") ?? true)
    }

    func testEditFailureNamesUpdateAndKeepsThePresentedError() async {
        let diagnostics = IOSDiagnosticRecorderProbe()
        let model = IOSAppModel(library: JSONSnipLibrary.unavailable(), diagnostics: diagnostics.recorder)
        let snip = Snip(content: "Private original text", origin: .quickEntry)

        let updated = await model.editSnip(snip, content: "Private edited text")

        XCTAssertFalse(updated)
        XCTAssertEqual(model.errorMessage, SnipLibraryError.storeUnavailable.localizedDescription)
        XCTAssertEqual(diagnostics.events.count, 1)
        XCTAssertEqual(diagnostics.events.first?.operation, "snip.update")
        XCTAssertEqual(diagnostics.events.first?.errorCode, "library.storeUnavailable")
        XCTAssertFalse(diagnostics.events.first?.line.contains("Private") ?? true)
    }

    func testDeleteFailureNamesDeleteOnce() async {
        let diagnostics = IOSDiagnosticRecorderProbe()
        let snip = Snip(content: "Private deleted text", origin: .quickEntry)
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: [snip], failsDeletion: true),
            diagnostics: diagnostics.recorder)
        await model.load()

        let deleted = await model.deleteSnip(id: snip.id)

        XCTAssertFalse(deleted)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(diagnostics.events.count, 1)
        XCTAssertEqual(diagnostics.events.first?.operation, "snip.delete")
        XCTAssertEqual(diagnostics.events.first?.errorCode, "library.snipNotFound")
        XCTAssertFalse(diagnostics.events.first?.line.contains("Private") ?? true)
    }

    func testUnsupportedListIconKeepsItsSavedChoiceAndVisibleIdentity() {
        let savedSymbol = "snipsnap.future-symbol"
        let list = SnipList(id: UUID(), name: "Future", systemImage: savedSymbol, position: 1)

        XCTAssertEqual(list.displaySystemImage, "list.bullet")
        XCTAssertEqual(list.systemImage, savedSymbol)
        XCTAssertEqual(SnipList.inbox.displaySystemImage, SnipList.inbox.systemImage)
    }

    func testControlTintUsesTheMonochromeActionPair() throws {
        for (style, fillWhite, labelWhite) in [
            (UIUserInterfaceStyle.light, 0.16, 1.0),
            (.dark, 0.92, 0.10),
        ] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let tint = UIColor(SnipSnapTheme.controlTint).resolvedColor(with: traits)
            let label = UIColor(SnipSnapTheme.actionLabel).resolvedColor(with: traits)
            var tintRed: CGFloat = 0
            var tintGreen: CGFloat = 0
            var tintBlue: CGFloat = 0
            var labelRed: CGFloat = 0
            var labelGreen: CGFloat = 0
            var labelBlue: CGFloat = 0
            XCTAssertTrue(tint.getRed(&tintRed, green: &tintGreen, blue: &tintBlue, alpha: nil))
            XCTAssertTrue(label.getRed(&labelRed, green: &labelGreen, blue: &labelBlue, alpha: nil))
            XCTAssertEqual(tintRed, fillWhite, accuracy: 0.001)
            XCTAssertEqual(tintGreen, fillWhite, accuracy: 0.001)
            XCTAssertEqual(tintBlue, fillWhite, accuracy: 0.001)
            XCTAssertEqual(labelRed, labelWhite, accuracy: 0.001)
            XCTAssertEqual(labelGreen, labelWhite, accuracy: 0.001)
            XCTAssertEqual(labelBlue, labelWhite, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(
                contrastRatio(tint, label),
                4.5,
                "Action controls need readable label contrast in style \(style.rawValue)."
            )
        }
    }

    func testAttachmentDraftCleanupWaitsForChildPresentations() {
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: true,
                isStaging: false,
                isImporting: false,
                isPickingMedia: false,
                isPreviewing: false
            )
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: false,
                isStaging: true,
                isImporting: false,
                isPickingMedia: false,
                isPreviewing: false
            )
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: false,
                isStaging: false,
                isImporting: true,
                isPickingMedia: false,
                isPreviewing: false
            )
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: false,
                isStaging: false,
                isImporting: false,
                isPickingMedia: true,
                isPreviewing: false
            )
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: false,
                isStaging: false,
                isImporting: false,
                isPickingMedia: false,
                isPreviewing: true
            )
        )
        XCTAssertTrue(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: false,
                isStaging: false,
                isImporting: false,
                isPickingMedia: false,
                isPreviewing: false
            )
        )
    }

    func testTextSnipFlowCreatesEditsMovesAndDeletes() async throws {
        let library = ModelTestLibrary()
        let model = makeModel(library: library)
        await model.load()

        let createdList = await model.createList(name: "Work")
        XCTAssertTrue(createdList)
        let workID = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" })?.id)
        let createdSnip = await model.createSnip(content: "First draft", in: SnipList.inboxID)
        XCTAssertTrue(createdSnip)
        let snip = try XCTUnwrap(model.selectedSnip)

        let editedSnip = await model.editSnip(snip, content: "Final draft")
        XCTAssertTrue(editedSnip)
        XCTAssertEqual(model.selectedSnip?.content, "Final draft")

        let movedSnip = await model.moveSnip(id: snip.id, to: workID)
        XCTAssertTrue(movedSnip)
        XCTAssertEqual(model.lastSelectedListID, workID)
        XCTAssertEqual(model.selectedSnip?.listID, workID)

        let deletedSnip = await model.deleteSnip(id: snip.id)
        XCTAssertTrue(deletedSnip)
        XCTAssertTrue(model.snips.isEmpty)
        XCTAssertNil(model.selectedSnipID)
        let pruneCalls = await library.pruneCalls()
        XCTAssertGreaterThan(pruneCalls, 0)
    }

    func testQuickComposerCreateDoesNotChangeTheCurrentSelection() async throws {
        let library = ModelTestLibrary()
        let model = makeModel(library: library)
        await model.load()
        let createdList = await model.createList(name: "Work")
        XCTAssertTrue(createdList)
        let workID = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" })?.id)
        model.selectList(SnipList.inboxID)
        model.selectedSnipID = nil

        let created = await model.createSnip(
            content: "Saved in the background",
            in: workID,
            selectCreatedSnip: false
        )

        XCTAssertTrue(created)
        XCTAssertEqual(model.lastSelectedListID, SnipList.inboxID)
        XCTAssertNil(model.selectedSnipID)
        XCTAssertEqual(model.snips.first(where: { $0.content == "Saved in the background" })?.listID, workID)
    }

    func testRecoveryReviewLoadsScopedAttentionRefreshesCurrentAndResolves() async throws {
        let namespace = ICloudSyncNamespaceBinding(
            scope: "private",
            accountLineage: "account-a",
            generation: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            zones: [ICloudSyncZoneBinding(name: "SnipSnap", ownerName: "owner-a")]
        )
        let current = Snip(content: "Current", origin: .quickEntry)
        let recoveredValue = Snip(id: UUID(), content: "Recovered", origin: .quickEntry)
        let recovered = RecoveredSnip(
            id: recoveredValue.id,
            currentSnipID: current.id,
            recovered: recoveredValue,
            conflictingFields: [.text]
        )
        let library = ModelTestLibrary(
            snips: [current],
            recovery: SnipRecoverySnapshot(pendingSnips: [recovered])
        )
        let assembly = SnipLibraryAssembly(
            library: library,
            activeCloudNamespace: namespace
        )
        XCTAssertNotNil(assembly.recoveryScope)
        let model = IOSAppModel(
            library: assembly.library,
            recoveryScope: assembly.recoveryScope
        )

        await model.load()
        XCTAssertEqual(model.recoverySnapshot.needsAttentionCount, 1)
        XCTAssertEqual(model.recoverySnapshot.pendingSnips, [recovered])
        await library.replaceText("Changed while open", for: current.id)
        await model.load()
        XCTAssertEqual(model.currentSnip(for: recovered)?.content, "Changed while open")

        let resolved = await model.resolveRecovery(recovered.id, choice: .keepCurrent)
        XCTAssertTrue(resolved)
        let choices = await library.resolutionChoices()
        XCTAssertEqual(choices, [.keepCurrent])
        XCTAssertEqual(model.recoverySnapshot.needsAttentionCount, 0)
    }

    func testShippedAssemblyReadsExactCloudScopeAndFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSAssemblyScopeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = ICloudSyncNamespaceBinding(
            scope: "private",
            accountLineage: "account-a",
            generation: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            zones: [ICloudSyncZoneBinding(name: "SnipSnap", ownerName: "owner-a")]
        )
        let cloudRoot = root.appendingPathComponent("Cloud", isDirectory: true)
        try writeActivationManifest(namespace: namespace, to: cloudRoot)
        let library = ModelTestLibrary()

        let cloudAssembly = SnipLibraryAssembly(
            library: library,
            syncModeRootURL: cloudRoot
        )

        XCTAssertEqual(
            SyncModeActivationManifestReader.activeCloudNamespace(
                atSyncModeRootURL: cloudRoot
            ),
            namespace
        )
        XCTAssertEqual(
            cloudAssembly.recoveryScope,
            SnipRecoveryScopeFactory.scope(forActiveCloudNamespace: namespace)
        )

        let localOnlyRoot = root.appendingPathComponent("LocalOnly", isDirectory: true)
        let localOnlyAssembly = SnipLibraryAssembly(
            library: library,
            syncModeRootURL: localOnlyRoot
        )
        XCTAssertNil(localOnlyAssembly.recoveryScope)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localOnlyRoot.path))

        let malformedRoot = root.appendingPathComponent("Malformed", isDirectory: true)
        try FileManager.default.createDirectory(at: malformedRoot, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: malformedRoot.appendingPathComponent("activation.json")
        )
        XCTAssertNil(
            SnipLibraryAssembly(library: library, syncModeRootURL: malformedRoot).recoveryScope
        )
    }

    func testAttachmentInputsUseTheTargetedLibraryCommands() async throws {
        let library = ModelTestLibrary()
        let model = makeModel(library: library)
        await model.load()
        let sourceURL = URL(fileURLWithPath: "/tmp/first-file.txt")
        let replacementURL = URL(fileURLWithPath: "/tmp/replacement-file.txt")

        let created = await model.createSnip(
            content: "",
            in: SnipList.inboxID,
            attachmentURLs: [sourceURL]
        )
        XCTAssertTrue(created)
        let addedURLs = await library.addedAttachmentURLs()
        XCTAssertEqual(addedURLs, [sourceURL])
        let snip = try XCTUnwrap(model.selectedSnip)

        let edited = await model.editSnip(
            snip,
            content: "Now with a file",
            attachmentEdits: [.added(sourceURL: replacementURL)]
        )
        XCTAssertTrue(edited)
        let edit = await library.lastAttachmentEdit
        XCTAssertEqual(edit?.snipID, snip.id)
        XCTAssertEqual(edit?.content, "Now with a file")
        XCTAssertEqual(edit?.edits, [.added(sourceURL: replacementURL)])
    }

    func testCameraPhotoStagesAsAUsableImageAttachment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapCameraStagingTests-\(UUID().uuidString)", isDirectory: true)
        defer { AttachmentDraftStager.clean(root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }

        let staged = try await AttachmentMediaStager.stageCameraImage(image, in: root)
        let values = try staged.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        XCTAssertTrue(values.isRegularFile == true)
        XCTAssertFalse(values.isSymbolicLink == true)
        XCTAssertGreaterThan(staged.byteCount, 0)
        XCTAssertNotNil(UIImage(contentsOfFile: staged.url.path))
        XCTAssertTrue(AttachmentImageType.isImage(fileName: staged.fileName))
    }

    func testCancelledCameraPhotoLeavesNoStagedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapCameraCancellationTests-\(UUID().uuidString)", isDirectory: true)
        defer { AttachmentDraftStager.clean(root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AttachmentMediaStager.stageCameraImage(image, in: root)
        }

        do {
            _ = try await task.value
            XCTFail("A cancelled camera import must not publish a staged file.")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testDeleteToastRestoresTheSnipWithoutKeepingSelectionHistory() async throws {
        let library = ModelTestLibrary()
        let model = makeModel(library: library)
        await model.load()
        let didCreate = await model.createSnip(content: "Keep me", in: SnipList.inboxID)
        XCTAssertTrue(didCreate)
        let id = try XCTUnwrap(model.selectedSnipID)

        let didDelete = await model.deleteSnip(id: id)
        XCTAssertTrue(didDelete)
        let toast = try XCTUnwrap(model.toast)
        XCTAssertEqual(toast.message, "Snip deleted")
        XCTAssertEqual(toast.action, .undoDelete)
        XCTAssertFalse(model.snips.contains { $0.id == id })

        await model.performToastActionNow(toast)

        XCTAssertTrue(model.snips.contains { $0.id == id })
        XCTAssertTrue(model.selectedSnipIDs.isEmpty)
        XCTAssertNil(model.toast)
    }

    func testTargetCannotCompileAppKit() {
        #if canImport(AppKit)
        XCTFail("The universal iOS target must not compile AppKit.")
        #endif
    }

    private func contrastRatio(_ first: UIColor, _ second: UIColor) -> CGFloat {
        let lighter = max(relativeLuminance(first), relativeLuminance(second))
        let darker = min(relativeLuminance(first), relativeLuminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: nil) else {
            XCTFail("Action colors must resolve to RGB values.")
            return 0
        }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

private func writeActivationManifest(
    namespace: ICloudSyncNamespaceBinding,
    to rootURL: URL
) throws {
    let storeID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let namespaceData = try JSONEncoder().encode(namespace)
    let namespaceValue = try JSONSerialization.jsonObject(with: namespaceData)
    let manifest: [String: Any] = [
        "version": 2,
        "activeStoreID": storeID.uuidString,
        "stores": [[
            "id": storeID.uuidString,
            "kind": "iCloudSync",
            "namespace": namespaceValue,
            "relativeRoot": "stores/iCloudSync-\(storeID.uuidString.lowercased())",
            "syncProtocol": "fullRecordV1",
            "revision": 0,
            "lifecycle": "ready"
        ]]
    ]
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(
        to: rootURL.appendingPathComponent("activation.json")
    )
}
