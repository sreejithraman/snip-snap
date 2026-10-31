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
        let files = try await ComposerPasteboard.stageAttachments(providers, in: root.appendingPathComponent("Draft"))

        XCTAssertEqual(input.text, "keep")
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
}
