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
final class IOSComposerTests: IOSModelTestCase {
    func testComposerPasteStagesCopiedPhotoWithoutPastingItsFileURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("sample.png")
        let data = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        try data.write(to: photo)
        let name = UIPasteboard.Name("SnipSnapComposerPaste.\(UUID().uuidString)")
        let pasteboard = try XCTUnwrap(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        let writer = IOSSystemPasteboard(pasteboard: pasteboard, stagingRoot: root.appendingPathComponent("Copy"))
        XCTAssertTrue(writer.write([.file(photo)]))
        let input = ComposerTextView()
        input.text = "keep"
        var providers: [NSItemProvider] = []
        input.onPasteAttachments = { items, _ in providers = items }

        input.paste(itemProviders: pasteboard.itemProviders)
        let pasted = try await ComposerPasteboard.stage(providers, in: root.appendingPathComponent("Draft"))
        let files = pasted.files

        XCTAssertEqual(input.text, "keep")
        XCTAssertEqual(pasted.text, "")
        XCTAssertEqual(files.map(\.fileName), ["sample.png"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first).url), data)
        pasteboard.string = "Clipboard changed"
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first).url), data)
    }

    func testComposerPasteInsertsMixedTextAtSelectionAndAttachesRawImage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let input = ComposerTextView()
        input.text = "before after"
        input.selectedRange = NSRange(location: 7, length: 0)
        var providers: [NSItemProvider] = []
        var selection = NSRange()
        input.onPasteAttachments = { items, range in providers = items; selection = range }

        input.paste(itemProviders: [
            NSItemProvider(object: "hello " as NSString), NSItemProvider(object: image),
        ])
        let pasted = try await ComposerPasteboard.stage(providers, in: root)

        XCTAssertEqual(pasted.inserting(into: input.text, at: selection), "before hello after")
        XCTAssertEqual(pasted.files.count, 1)
        XCTAssertNotNil(UIImage(contentsOfFile: try XCTUnwrap(pasted.files.first).url.path))
    }

    func testComposerPasteFailureAndCancellationCleanStagedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = NSItemProvider()
        broken.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            completion(nil, false, CocoaError(.fileReadNoSuchFile))
            return nil
        }
        do {
            _ = try await ComposerPasteboard.stageAttachments([broken], in: root)
            XCTFail("Unreadable photo must report a failure")
        } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        let task = Task {
            try Task.checkCancellation()
            return try await ComposerPasteboard.stageAttachments([broken], in: root)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled paste must not leave an attachment")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testComposerPasteCancellationInterruptsAnActiveProviderAndCleansEarlierPhoto() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: photo)
        let started = expectation(description: "Second photo began loading")
        let finished = expectation(description: "Cancellation finishes without waiting for provider")
        let cancelled = expectation(description: "Provider progress cancelled")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let progress = Progress(totalUnitCount: 1)
        progress.cancellationHandler = { cancelled.fulfill() }
        let slow = NSItemProvider()
        slow.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            started.fulfill()
            DispatchQueue.global().async {
                release.wait()
                completion(photo, false, nil)
            }
            return progress
        }
        let staging = root.appendingPathComponent("Draft")
        let task = Task {
            do {
                _ = try await ComposerPasteboard.stageAttachments([NSItemProvider(contentsOf: photo)!, slow], in: staging)
                XCTFail("Cancelled paste must not succeed")
            } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [finished, cancelled], timeout: 1)
        release.signal()
        await task.value
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    func testMixedComposerPasteWaitsForDelayedTextAndKeepsItsCapturedSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "Text provider loading")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let text = NSItemProvider()
        text.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
            started.fulfill()
            DispatchQueue.global().async {
                release.wait()
                completion(Data("hello ".utf8), nil)
            }
            return nil
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        var finished = false
        let task = Task {
            let result = try await ComposerPasteboard.stage([text, NSItemProvider(object: image)], in: root)
            finished = true
            return result
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(finished, "A paste cannot finish while its text is still loading")
        release.signal()
        let result = try await task.value
        XCTAssertEqual(result.inserting(into: "before after", at: NSRange(location: 7, length: 0)), "before hello after")
        XCTAssertEqual(result.files.count, 1)
    }

    func testLargeMixedComposerPasteKeepsBodyAndStagesTextWithPhoto() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = String(repeating: "p", count: LargePastedText.attachmentCharacterLimit)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let result = try await ComposerPasteboard.stage([
            NSItemProvider(object: text as NSString), NSItemProvider(object: image),
        ], in: root)
        XCTAssertEqual(result.inserting(into: "before after", at: NSRange(location: 7, length: 0)), "before after")
        XCTAssertEqual(result.files.count, 2)
        let textFile = try XCTUnwrap(result.files.first(where: { $0.url.pathExtension == "txt" }))
        XCTAssertEqual(try String(contentsOf: textFile.url, encoding: .utf8), text)
    }

    func testDelayedMixedComposerPasteKeepsCaretAtCapturedInsertionAfterUserMovesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var body = "before after"
        var providers: [NSItemProvider] = []
        var selection = NSRange()
        func input() -> ComposerTextInput {
            ComposerTextInput(
                prompt: "Paste here",
                text: Binding(get: { body }, set: { body = $0 }),
                isFocused: .constant(false),
                onPasteAttachments: { providers = $0; selection = $1 }
            )
        }
        let host = UIHostingController(rootView: input())
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        func textView(in view: UIView) -> ComposerTextView? {
            if let input = view as? ComposerTextView { return input }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        let view = try XCTUnwrap(textView(in: host.view))
        view.selectedRange = NSRange(location: 7, length: 0)
        let started = expectation(description: "Text provider started")
        let release = DispatchSemaphore(value: 0)
        let text = NSItemProvider()
        text.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
            started.fulfill()
            DispatchQueue.global().async {
                release.wait()
                completion(Data("hello ".utf8), nil)
            }
            return Progress(totalUnitCount: 1)
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        view.paste(itemProviders: [text, NSItemProvider(object: image)])
        let task = Task { try await ComposerPasteboard.stage(providers, in: root) }
        await fulfillment(of: [started], timeout: 2)
        view.selectedRange = NSRange(location: 0, length: 0)
        release.signal()
        let result = try await task.value
        body = result.inserting(into: body, at: selection)
        host.rootView = input()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        XCTAssertEqual(view.text, "before hello after")
        XCTAssertEqual(view.selectedRange, NSRange(location: 13, length: 0))
        view.insertText("there ")
        XCTAssertEqual(body, "before hello there after")
    }

    func testComposerFocusUpdatesDoNotWriteBindingsDuringViewUpdates() throws {
        var focused = false
        var enabled = true
        var isUpdating = false
        var writesDuringUpdate = 0
        func input() -> ComposerTextInput {
            ComposerTextInput(
                prompt: "Add a snip",
                text: .constant("Draft"),
                isFocused: Binding(get: { focused }, set: {
                    if isUpdating { writesDuringUpdate += 1 }
                    focused = $0
                }),
                isEnabled: enabled,
                onPasteAttachments: { _, _ in }
            )
        }
        let host = UIHostingController(rootView: input())
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        func textView(in view: UIView) -> ComposerTextView? {
            if let input = view as? ComposerTextView { return input }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        let view = try XCTUnwrap(textView(in: host.view))
        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertTrue(focused, "User focus must still reach SwiftUI")

        func update() {
            isUpdating = true
            host.rootView = input()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            isUpdating = false
        }
        focused = false
        update()
        XCTAssertFalse(view.isFirstResponder)
        XCTAssertEqual(writesDuringUpdate, 0, "SwiftUI-driven focus must not echo through its binding")

        focused = true
        update()
        XCTAssertTrue(view.isFirstResponder)
        XCTAssertEqual(writesDuringUpdate, 0)

        enabled = false
        update()
        XCTAssertFalse(view.isFirstResponder)
        XCTAssertTrue(focused, "Disabling input must preserve SwiftUI's requested focus")
        XCTAssertEqual(writesDuringUpdate, 0)

        enabled = true
        update()
        XCTAssertTrue(view.isFirstResponder)
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertFalse(focused, "User blur must still reach SwiftUI")
    }

    func testComposerKeepsCursorWhenLargePlainTextPasteBecomesAnAttachment() async throws {
        var body = "before after"
        var focused = false
        var divertedText: String?
        let pastedText = String(repeating: "p", count: LargePastedText.attachmentCharacterLimit)
        let attached = expectation(description: "Large text diverted to attachment")
        let input = ComposerTextInput(
            prompt: "Paste here",
            text: Binding(get: { body }, set: { value in
                if let insertion = LargePastedText.largeInsertion(from: body, to: value) {
                    divertedText = insertion
                    attached.fulfill()
                } else { body = value }
            }),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
            onPasteAttachments: { _, _ in }
        )
        let host = UIHostingController(rootView: input)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        func textView(in view: UIView) -> ComposerTextView? {
            if let input = view as? ComposerTextView { return input }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        let view = try XCTUnwrap(textView(in: host.view))
        let editing = expectation(forNotification: UITextView.textDidBeginEditingNotification, object: view)
        XCTAssertTrue(view.becomeFirstResponder())
        await fulfillment(of: [editing], timeout: 2)
        XCTAssertTrue(view.isFirstResponder)
        XCTAssertTrue(focused)
        XCTAssertEqual(view.text, body)
        view.smartInsertDeleteType = .no
        view.selectedRange = NSRange(location: 7, length: 0)
        view.paste(itemProviders: [NSItemProvider(object: pastedText as NSString)])
        await fulfillment(of: [attached], timeout: 2)
        XCTAssertEqual(divertedText, pastedText)
        XCTAssertEqual(body, "before after")
        XCTAssertEqual(view.text, "before after")
        XCTAssertEqual(view.selectedRange, NSRange(location: 7, length: 0))
        view.insertText("hello ")
        XCTAssertEqual(body, "before hello after")
    }

    func testComposerDraftsStaySeparateAndPreserveNewTextDuringSave() {
        let suiteName = "IOSComposerDraftTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ComposerDraftStore(
            defaults: defaults,
            textDefaultsKey: "drafts"
        )
        let workID = UUID()
        store.setText("Inbox draft", for: SnipList.inboxID)
        store.setText("Work draft", for: workID)

        let snapshot = store.beginSave(listID: SnipList.inboxID)
        store.setText("New inbox text", for: SnipList.inboxID)
        store.finishSave(snapshot, saved: true)

        XCTAssertEqual(store.draft(for: SnipList.inboxID).text, "New inbox text")
        XCTAssertEqual(store.draft(for: workID).text, "Work draft")
    }

    private func clipboard(_ data: Data, type: String) -> UIPasteboard {
        let board = UIPasteboard.withUniqueName()
        addTeardownBlock { UIPasteboard.remove(withName: board.name) }
        board.setData(data, forPasteboardType: type)
        return board
    }

    private func stagingRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testPasteKeepsNonTextClipboardDataAsAnAttachment() async throws {
        let bytes = Data("%PDF-1.4".utf8)
        for type in [UTType.pdf.identifier, UTType.mpeg4Movie.identifier, "com.example.custom"] {
            let board = clipboard(bytes, type: type)
            let result = try await ComposerPasteboard.stage(board.itemProviders, in: stagingRoot())
            XCTAssertEqual(result.text, "", type)
            let file = try XCTUnwrap(result.files.first, type)
            XCTAssertEqual(result.files.count, 1, type)
            XCTAssertEqual(try Data(contentsOf: file.url), bytes, type)
            XCTAssertEqual(file.byteCount, Int64(bytes.count), type)
        }
    }

    /// One clipboard item offering each representation, in registration order.
    private func item(_ representations: [(type: String, data: Data)]) -> NSItemProvider {
        let provider = NSItemProvider()
        for (type, data) in representations {
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) {
                $0(data, nil)
                return nil
            }
        }
        XCTAssertEqual(provider.registeredTypeIdentifiers, representations.map(\.type))
        return provider
    }

    private func pngData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    func testPasteKeepsTextAndImageFromTheSameItem() async throws {
        let png = pngData()
        let provider = item([(UTType.utf8PlainText.identifier, Data("Cell text".utf8)), (UTType.png.identifier, png)])
        let input = ComposerTextView()
        input.text = "before  after"
        input.selectedRange = NSRange(location: 7, length: 0)
        var providers: [NSItemProvider] = []
        var selection = NSRange()
        input.onPasteAttachments = { items, range in providers = items; selection = range }

        input.paste(itemProviders: [provider])
        let result = try await ComposerPasteboard.stage(providers, in: stagingRoot())

        XCTAssertEqual(result.text, "Cell text")
        XCTAssertEqual(result.inserting(into: input.text, at: selection), "before Cell text after")
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.files.first).url), png)
    }

    func testPasteKeepsWebLinkTextWithItsImage() async throws {
        let png = pngData()
        let provider = item([(UTType.png.identifier, png), (UTType.utf8PlainText.identifier, Data("https://example.com/a.png".utf8))])
        let result = try await ComposerPasteboard.stage([provider], in: stagingRoot())
        XCTAssertEqual(result.text, "https://example.com/a.png")
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.files.first).url), png)
    }

    func testPasteLeavesAnImageFileURLOutOfTheBody() async throws {
        let png = pngData()
        let provider = item([(UTType.png.identifier, png), (UTType.utf8PlainText.identifier, Data(" file:///private/Folder/photo.png\n".utf8))])
        let result = try await ComposerPasteboard.stage([provider], in: stagingRoot())
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.files.first).url), png)
    }

    func testPasteKeepsTextAndAFileFromTheSameItem() async throws {
        let pdf = Data("%PDF-1.4".utf8)
        let text = (type: UTType.utf8PlainText.identifier, data: Data("Cell text".utf8))
        let file = (type: UTType.pdf.identifier, data: pdf)
        for representations in [[text, file], [file, text]] {
            let result = try await ComposerPasteboard.stage([item(representations)], in: stagingRoot())
            XCTAssertEqual(result.text, "Cell text", "\(representations.map(\.type))")
            XCTAssertEqual(result.files.count, 1, "\(representations.map(\.type))")
            let saved = try XCTUnwrap(result.files.first)
            XCTAssertEqual(try Data(contentsOf: saved.url), pdf)
            XCTAssertEqual(saved.url.pathExtension, "pdf")
        }
    }

    func testComposerRoutesTextWithAFileToAttachments() {
        let input = ComposerTextView()
        input.text = "keep"
        var routed: [NSItemProvider] = []
        input.onPasteAttachments = { items, _ in routed = items }
        let provider = item([(UTType.utf8PlainText.identifier, Data("Cell text".utf8)), (UTType.pdf.identifier, Data("%PDF-1.4".utf8))])

        input.paste(itemProviders: [provider])

        XCTAssertEqual(routed, [provider])
        XCTAssertEqual(input.text, "keep")
    }

    func testPasteKeepsRichTextAlternativesAsTextOnly() async throws {
        let text = (type: UTType.utf8PlainText.identifier, data: Data("Note".utf8))
        let rich = [UTType.html, .flatRTFD, .rtf].map { (type: $0.identifier, data: Data("rich".utf8)) }
        let archive = (type: UTType.webArchive.identifier, data: Data("archive".utf8))
        for representations in [[text] + rich, [text, archive]] {
            let result = try await ComposerPasteboard.stage([item(representations)], in: stagingRoot())
            XCTAssertEqual(result.text, "Note", "\(representations.map(\.type))")
            XCTAssertTrue(result.files.isEmpty, "\(representations.map(\.type))")
        }
    }

    func testPastePrefersDeclaredDataOverAPrivateReference() async throws {
        let bytes = Data("extensionless file".utf8)
        let provider = item([("com.apple.finder.node", Data("bplist00 file reference".utf8)), (UTType.data.identifier, bytes)])
        let result = try await ComposerPasteboard.stage([provider], in: stagingRoot())
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.files.first).url), bytes)
    }

    func testPastePrefersAFileTypeOverAPrivateReference() async throws {
        let pdf = Data("%PDF-1.4 test".utf8)
        let provider = item([("com.apple.finder.node", Data("bplist00 file reference".utf8)), (UTType.pdf.identifier, pdf)])

        let result = try await ComposerPasteboard.stage([provider], in: stagingRoot())
        XCTAssertEqual(result.files.count, 1)
        let file = try XCTUnwrap(result.files.first)
        XCTAssertEqual(try Data(contentsOf: file.url), pdf)
        XCTAssertEqual(file.url.pathExtension, "pdf")
    }

    func testPasteNamesAttachmentForItsClipboardType() async throws {
        let board = clipboard(Data("%PDF-1.4".utf8), type: UTType.pdf.identifier)
        let result = try await ComposerPasteboard.stage(board.itemProviders, in: stagingRoot())
        XCTAssertEqual(try XCTUnwrap(result.files.first).url.pathExtension, "pdf")
    }

    func testPasteReadsRichTextOnlyClipboardAsText() async throws {
        let rtf = try NSAttributedString(string: "Rich").data(
            from: NSRange(location: 0, length: 4),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let board = clipboard(rtf, type: UTType.rtf.identifier)
        let result = try await ComposerPasteboard.stage(board.itemProviders, in: stagingRoot())
        XCTAssertEqual(result.text.trimmingCharacters(in: .whitespacesAndNewlines), "Rich")
        XCTAssertTrue(result.files.isEmpty)
    }

    func testPasteReadsLinkOnlyClipboardAsText() async throws {
        let board = UIPasteboard.withUniqueName()
        addTeardownBlock { UIPasteboard.remove(withName: board.name) }
        board.url = URL(string: "https://example.com/page")
        let result = try await ComposerPasteboard.stage(board.itemProviders, in: stagingRoot())
        XCTAssertEqual(result.text, "https://example.com/page")
        XCTAssertTrue(result.files.isEmpty)
    }

    func testPasteAndSaveReportsAnEmptyClipboardWithoutCheckingAccess() async throws {
        let board = UIPasteboard.withUniqueName()
        addTeardownBlock { UIPasteboard.remove(withName: board.name) }
        for content in [nil, " \n"] {
            board.string = content
            var accessChecks = 0
            do {
                _ = try await ComposerPasteboard.stageForSaving(
                    from: board, in: stagingRoot(), requestAccess: { _ in accessChecks += 1 })
                XCTFail("Nothing to save: \(String(describing: content))")
            } catch {
                XCTAssertEqual(error as? ComposerPasteFailure, .empty)
            }
            XCTAssertEqual(accessChecks, 0)
        }
    }

    /// A clipboard item whose load fails, as iOS fails loads before the paste permission passes.
    private func refusedItem() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.pdf.identifier, visibility: .all) {
            $0(nil, NSError(domain: NSItemProvider.errorDomain, code: NSItemProvider.ErrorCode.itemUnavailableError.rawValue))
            return nil
        }
        return provider
    }

    func testPasteAndSaveChecksAccessOnlyAfterALoadFailsAndRetriesOnce() async throws {
        let pdf = Data("%PDF-1.4".utf8)
        let board = clipboard(pdf, type: UTType.pdf.identifier)
        let root = stagingRoot()
        var loads: [[NSItemProvider]] = []
        var accessChecks = 0
        func stage(
            _ attempts: [[NSItemProvider]], access: @MainActor (UIPasteboard) throws -> Void
        ) async throws -> ComposerPastedContent {
            loads = attempts
            accessChecks = 0
            return try await ComposerPasteboard.stageForSaving(
                from: board, in: root,
                providers: { _ in loads.removeFirst() },
                requestAccess: { accessChecks += 1; try access($0) })
        }
        func stagedFiles() -> [URL] {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]
            return (files ?? []).filter { !$0.hasDirectoryPath }
        }

        let loaded = try await stage([board.itemProviders]) { _ in }
        XCTAssertEqual(accessChecks, 0)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(loaded.files.first).url), pdf)
        AttachmentDraftStager.clean(loaded.files)

        let retried = try await stage([[refusedItem()], board.itemProviders], access: ComposerPasteboard.requestAccess(to:))
        XCTAssertEqual(accessChecks, 1)
        XCTAssertTrue(loads.isEmpty)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(retried.files.first).url), pdf)
        AttachmentDraftStager.clean(retried.files)

        do {
            _ = try await stage([[refusedItem()], board.itemProviders]) { _ in throw ComposerPasteFailure.unreadable }
            XCTFail("A refused access check must not retry")
        } catch {
            XCTAssertEqual(error as? ComposerPasteFailure, .unreadable)
            XCTAssertEqual(accessChecks, 1)
            XCTAssertEqual(loads.count, 1, "The retry load must not run")
        }

        do {
            _ = try await stage([[board.itemProviders[0], refusedItem()], [refusedItem()], board.itemProviders]) { _ in }
            XCTFail("A failed retry must surface its error")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSItemProvider.errorDomain)
            XCTAssertEqual(accessChecks, 1)
            XCTAssertEqual(loads.count, 1, "Only one retry may run")
        }
        XCTAssertEqual(stagedFiles(), [], "Failed loads must not leave staged files")
    }

    func testPasteAccessAcceptsTextOrALinkInAnyItem() throws {
        let board = UIPasteboard.withUniqueName()
        addTeardownBlock { UIPasteboard.remove(withName: board.name) }
        let pdf = [UTType.pdf.identifier: Data("%PDF-1.4".utf8)] as [String: Any]
        let text = [UTType.utf8PlainText.identifier: "Note"] as [String: Any]
        let link = [UTType.url.identifier: URL(string: "https://example.com")!] as [String: Any]
        for items in [[text, pdf], [pdf, text], [pdf, link]] {
            board.items = items
            XCTAssertNoThrow(try ComposerPasteboard.requestAccess(to: board), "\(board.types)")
        }
    }

    func testPasteAccessAcceptsAFileWithAPrivateReference() throws {
        let reference = "com.apple.finder.node"
        for order in [[reference, UTType.pdf.identifier], [UTType.pdf.identifier, reference]] {
            let board = UIPasteboard.withUniqueName()
            addTeardownBlock { UIPasteboard.remove(withName: board.name) }
            board.setItemProviders([item(order.map { ($0, Data($0.utf8)) })], localOnly: true, expirationDate: nil)
            XCTAssertEqual(board.types, order)
            XCTAssertNoThrow(try ComposerPasteboard.requestAccess(to: board), "\(order)")
        }
    }

    func testPasteFailuresKeepTheirDiagnosticCodes() {
        let diagnostics = IOSDiagnosticRecorderProbe()
        let model = IOSAppModel(library: JSONSnipLibrary.unavailable(), diagnostics: diagnostics.recorder)
        for failure in [ComposerPasteFailure.empty, .unreadable] {
            model.presentError(failure.message, operation: "snip.paste_read", diagnosticCode: failure.diagnosticCode)
        }
        XCTAssertEqual(diagnostics.events.map(\.errorCode), ["snip.emptyClipboard", "snip.clipboardUnreadable"])
    }

    func testPasteAndSaveReadsEveryClipboardType() async throws {
        for type in [UTType.pdf.identifier, UTType.utf8PlainText.identifier, "com.example.custom"] {
            let board = clipboard(Data("content".utf8), type: type)
            let pasted = try await ComposerPasteboard.stageForSaving(from: board, in: stagingRoot())
            XCTAssertTrue(!pasted.text.isEmpty || !pasted.files.isEmpty, type)
        }
    }
}
