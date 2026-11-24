import Observation
import ImageIO
import PhotosUI
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
    override func setUp() async throws {
        try await super.setUp()
        await TestKeyboard.warmUp()
    }

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
            _ = try await ComposerPasteboard.stage([broken], in: root)
            XCTFail("Unreadable photo must report a failure")
        } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        let task = Task {
            try Task.checkCancellation()
            return try await ComposerPasteboard.stage([broken], in: root)
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
                _ = try await ComposerPasteboard.stage([NSItemProvider(contentsOf: photo)!, slow], in: staging)
                XCTFail("Cancelled paste must not succeed")
            } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: TestReadiness.timeout)
        task.cancel()
        await fulfillment(of: [finished, cancelled], timeout: TestReadiness.timeout)
        release.signal()
        await task.value
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    func testComposerPasteCancelledBeforeItStartsNeverLoadsItsProviders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let loads = ProviderHandlerCounter()
        let text = NSItemProvider()
        text.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
            loads.record()
            completion(Data("hello".utf8), nil)
            return nil
        }
        let photo = NSItemProvider()
        photo.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            loads.record()
            completion(nil, false, CocoaError(.fileReadNoSuchFile))
            return nil
        }
        let staging = root.appendingPathComponent("Draft")
        let task = Task { try await ComposerPasteboard.stage([text, photo], in: staging) }
        task.cancel()
        let settled = await settledResult(of: task)
        let result = try XCTUnwrap(settled)
        do {
            _ = try result.get()
            XCTFail("Cancelled paste must not succeed")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertEqual(loads.count, 0)
        XCTAssertEqual(stagedEntries(in: staging), [])
    }

    func testPhotoImportCancelledBeforeItStartsThrowsCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            try await AttachmentMediaStager.stagePhotos([PhotosPickerItem(itemIdentifier: UUID().uuidString)], in: root)
        }
        task.cancel()
        let settled = await settledResult(of: task)
        let result = try XCTUnwrap(settled)
        do {
            _ = try result.get()
            XCTFail("Cancelled photo import must not succeed")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertEqual(stagedEntries(in: root), [])
    }

    func testComposerPasteCancelledWhileTextIsLoadingThrowsAndCancelsItsProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "Text provider began loading")
        let cancelled = expectation(description: "Text provider progress cancelled")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let progress = Progress(totalUnitCount: 1)
        progress.cancellationHandler = { cancelled.fulfill() }
        let text = NSItemProvider()
        text.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
            started.fulfill()
            DispatchQueue.global().async {
                release.wait()
                completion(Data("late".utf8), nil)
            }
            return progress
        }
        let task = Task { try await ComposerPasteboard.stage([text], in: root.appendingPathComponent("Draft")) }
        await fulfillment(of: [started], timeout: TestReadiness.timeout)
        task.cancel()
        let settled = await settledResult(of: task)
        let result = try XCTUnwrap(settled, "Cancellation must finish without waiting for the provider")
        do {
            _ = try result.get()
            XCTFail("Cancelled paste must not succeed")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        await fulfillment(of: [cancelled], timeout: TestReadiness.timeout)
        XCTAssertTrue(progress.isCancelled)
    }

    func testComposerPasteKeepsNothingWhenCancelledAfterAnEarlierLoadCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: photo)
        let started = expectation(description: "Photo began loading")
        let cancelled = expectation(description: "Photo progress cancelled")
        let delivered = expectation(description: "Photo provider called back late")
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
                delivered.fulfill()
            }
            return progress
        }
        let staging = root.appendingPathComponent("Draft")
        let task = Task { try await ComposerPasteboard.stage([NSItemProvider(object: "hello" as NSString), slow], in: staging) }
        await fulfillment(of: [started], timeout: TestReadiness.timeout)
        task.cancel()
        let settled = await settledResult(of: task)
        let result = try XCTUnwrap(settled)
        do {
            _ = try result.get()
            XCTFail("Cancelled paste must not succeed")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        await fulfillment(of: [cancelled], timeout: TestReadiness.timeout)
        release.signal()
        await fulfillment(of: [delivered], timeout: TestReadiness.timeout)
        XCTAssertEqual(stagedEntries(in: staging), [])
    }

    func testComposerPasteResumesOnceWhenAProviderCallsBackTwice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: photo)
        let file = NSItemProvider()
        file.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            DispatchQueue.global().async { completion(photo, false, nil) }
            DispatchQueue.global().async { completion(photo, false, nil) }
            return nil
        }
        let text = NSItemProvider()
        text.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
            DispatchQueue.global().async { completion(Data("first".utf8), nil) }
            DispatchQueue.global().async { completion(Data("second".utf8), nil) }
            return nil
        }
        let task = Task { try await ComposerPasteboard.stage([text, file], in: root.appendingPathComponent("Draft")) }
        let settled = await settledResult(of: task)
        let pasted = try XCTUnwrap(settled).get()
        XCTAssertTrue(["first", "second"].contains(pasted.text), "Only one callback's text is kept, got \(pasted.text)")
        XCTAssertEqual(pasted.files.count, 1)
    }

    func testComposerPasteNeverHandsOutAFileWhenCancellationRacesItsCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for iteration in 0..<50 {
            let photo = root.appendingPathComponent("photo-\(iteration).png")
            try Data([1, 2, 3]).write(to: photo)
            let started = expectation(description: "Photo \(iteration) began loading")
            let delivered = expectation(description: "Photo \(iteration) provider called back")
            let provider = NSItemProvider()
            provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
                started.fulfill()
                DispatchQueue.global().async {
                    completion(photo, false, nil)
                    delivered.fulfill()
                }
                return nil
            }
            let staging = root.appendingPathComponent("Draft-\(iteration)")
            let task = Task { try await ComposerPasteboard.stage([provider], in: staging) }
            await fulfillment(of: [started], timeout: TestReadiness.timeout)
            task.cancel()
            guard let result = await settledResult(of: task) else {
                XCTFail("Iteration \(iteration): paste did not settle")
                return
            }
            await fulfillment(of: [delivered], timeout: TestReadiness.timeout)
            switch result {
            case .success(let pasted):
                guard pasted.files.count == 1, let file = pasted.files.first else {
                    XCTFail("Iteration \(iteration): expected one pasted file, got \(pasted.files.count)")
                    return
                }
                guard FileManager.default.fileExists(atPath: file.url.path) else {
                    XCTFail("Iteration \(iteration): pasted file is missing at \(file.url.path)")
                    return
                }
                guard file.url.standardizedFileURL.path.hasPrefix(staging.standardizedFileURL.path + "/") else {
                    XCTFail("Iteration \(iteration): pasted file \(file.url.path) is outside \(staging.path)")
                    return
                }
            case .failure(let error) where error is CancellationError:
                let leaked = regularFilePaths(under: staging, relativeTo: root)
                guard leaked.isEmpty else {
                    XCTFail("Iteration \(iteration): cancelled paste left \(leaked.joined(separator: ", "))")
                    return
                }
                let entries = stagedEntries(in: staging)
                guard entries.isEmpty else {
                    XCTFail("Iteration \(iteration): cancelled paste left entries \(entries)")
                    return
                }
            case .failure(let error):
                XCTFail("Iteration \(iteration): expected success or cancellation, got \(error)")
                return
            }
        }
    }

    /// Waits for `task` with a timeout, so a load that never resumes fails the test instead of hanging the suite.
    private func settledResult<Success: Sendable>(of task: Task<Success, any Error>) async -> Result<Success, any Error>? {
        let settled = expectation(description: "Task settled")
        var result: Result<Success, any Error>?
        Task {
            result = await task.result
            settled.fulfill()
        }
        await fulfillment(of: [settled], timeout: TestReadiness.timeout)
        return result
    }

    private func stagedEntries(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    func testProviderLoadDeliversACompletionThatArrivesBeforeItsProgress() async throws {
        let progress = Progress(totalUnitCount: 1)
        let value = try await ProviderLoad<Int>.run { finish in
            finish { 7 }
            return progress
        }
        XCTAssertEqual(value, 7)
        XCTAssertFalse(progress.isCancelled)
    }

    func testProviderLoadDeliversOnlyItsFirstCompletion() async throws {
        var secondRan = false
        let value = try await ProviderLoad<Int>.run { finish in
            finish { 1 }
            finish {
                secondRan = true
                return 2
            }
            return Progress(totalUnitCount: 1)
        }
        XCTAssertEqual(value, 1)
        XCTAssertFalse(secondRan)
    }

    func testProviderLoadCancellationInterruptsTheProviderAndSkipsItsLateCompletion() async throws {
        let progress = Progress(totalUnitCount: 1)
        let started = expectation(description: "Provider load started")
        let captured = CapturedFinish<Int>()
        let task = Task {
            try await ProviderLoad<Int>.run { finish in
                captured.store(finish)
                started.fulfill()
                return progress
            }
        }
        await fulfillment(of: [started], timeout: TestReadiness.timeout)
        task.cancel()
        let settled = await settledResult(of: task)
        var lateRan = false
        captured.call {
            lateRan = true
            return 1
        }
        let result = try XCTUnwrap(settled)
        do {
            _ = try result.get()
            XCTFail("Cancelled load must not return a value")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertFalse(lateRan)
        XCTAssertTrue(progress.isCancelled)
    }

    func testProviderLoadCancelledBeforeItBeginsNeverStartsTheProvider() async {
        let task = Task {
            try await ProviderLoad<Int>.run { finish in
                XCTFail("A cancelled load must not start its provider")
                finish { 0 }
                return Progress()
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled load must not return a value")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
    }

    func testProviderLoadCancelsAProgressThatArrivesAfterCancellation() async throws {
        let progress = Progress(totalUnitCount: 1)
        let captured = CapturedFinish<Int>()
        let task = Task {
            try await ProviderLoad<Int>.run { finish in
                captured.store(finish)
                withUnsafeCurrentTask { $0?.cancel() }
                return progress
            }
        }
        let settled = await settledResult(of: task)
        captured.call { 0 }
        let result = try XCTUnwrap(settled)
        do {
            _ = try result.get()
            XCTFail("Cancelled load must not return a value")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertTrue(progress.isCancelled)
    }

    func testProviderLoadCancellationThatArrivesDuringTheResultBodyKeepsTheCompletion() async throws {
        let progress = Progress(totalUnitCount: 1)
        let started = expectation(description: "Provider load started")
        let inBody = expectation(description: "Result body running")
        let finished = expectation(description: "Load settled")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let captured = CapturedFinish<Int>()
        var outcome: Result<Int, any Error>?
        let task = Task {
            do {
                let value = try await ProviderLoad<Int>.run { finish in
                    captured.store(finish)
                    started.fulfill()
                    return progress
                }
                outcome = .success(value)
            } catch {
                outcome = .failure(error)
            }
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: TestReadiness.timeout)
        DispatchQueue.global().async {
            captured.call {
                inBody.fulfill()
                _ = release.wait(timeout: .now() + TestReadiness.timeout)
                return 7
            }
        }
        await fulfillment(of: [inBody], timeout: TestReadiness.timeout)
        task.cancel()
        // The body is parked in `release.wait`, so the cancellation above landed inside it.
        release.signal()
        await fulfillment(of: [finished], timeout: TestReadiness.timeout)
        XCTAssertEqual(try XCTUnwrap(outcome).get(), 7)
        XCTAssertFalse(progress.isCancelled)
    }

    func testProviderLoadCancellationDoesNotWaitForAnInProgressResultBody() async throws {
        let progress = Progress(totalUnitCount: 1)
        let started = expectation(description: "Provider load started")
        let inBody = expectation(description: "Result body running")
        let cancelReturned = expectation(description: "Cancel returned")
        let mayFinish = DispatchSemaphore(value: 0)
        defer { mayFinish.signal() }
        let bodyFinished = LockedFlag()
        let captured = CapturedFinish<Int>()
        let task = Task { () async throws -> (Int, Bool) in
            let value = try await ProviderLoad<Int>.run { finish in
                captured.store(finish)
                started.fulfill()
                return progress
            }
            return (value, Task.isCancelled)
        }
        await fulfillment(of: [started], timeout: TestReadiness.timeout)
        DispatchQueue.global().async {
            captured.call {
                inBody.fulfill()
                _ = mayFinish.wait(timeout: .now() + 2 * TestReadiness.timeout)
                bodyFinished.set()
                return 7
            }
        }
        await fulfillment(of: [inBody], timeout: TestReadiness.timeout)
        DispatchQueue.global().async {
            task.cancel()
            cancelReturned.fulfill()
        }
        await fulfillment(of: [cancelReturned], timeout: TestReadiness.timeout)
        XCTAssertFalse(bodyFinished.value, "Cancelling must not wait for a running result body")
        mayFinish.signal()
        let settled = await settledResult(of: task)
        let (value, sawCancellation) = try XCTUnwrap(settled).get()
        XCTAssertEqual(value, 7, "A claimed load keeps its value")
        XCTAssertTrue(sawCancellation, "The caller must still see the cancellation")
        XCTAssertFalse(progress.isCancelled)
    }

    func testProviderLoadRunsItsResultBodyExactlyWhenItDeliversTheValue() async throws {
        for iteration in 0..<200 {
            let started = expectation(description: "Load \(iteration) started")
            let delivered = expectation(description: "Load \(iteration) completion delivered")
            let bodyRuns = ProviderHandlerCounter()
            let captured = CapturedFinish<Int>()
            let task = Task {
                try await ProviderLoad<Int>.run { finish in
                    captured.store(finish)
                    started.fulfill()
                    return Progress(totalUnitCount: 1)
                }
            }
            await fulfillment(of: [started], timeout: TestReadiness.timeout)
            let callbackClaimsFirst = iteration.isMultiple(of: 2)
            DispatchQueue.global().async {
                captured.call {
                    bodyRuns.record()
                    return iteration
                }
                if callbackClaimsFirst { task.cancel() }
                delivered.fulfill()
            }
            if !callbackClaimsFirst { task.cancel() }
            guard let result = await settledResult(of: task) else {
                XCTFail("Iteration \(iteration): load did not settle")
                return
            }
            await fulfillment(of: [delivered], timeout: TestReadiness.timeout)
            let runs = bodyRuns.count
            switch result {
            case .success(let value) where value == iteration && runs == 1:
                continue
            case .failure(let error) where !callbackClaimsFirst && error is CancellationError && runs == 0:
                continue
            default:
                let order = callbackClaimsFirst ? "callback claimed first" : "callback raced cancel"
                XCTFail("Iteration \(iteration) (\(order)): got \(result) after \(runs) body runs")
                return
            }
        }
    }

    func testMixedComposerPasteWaitsForDelayedText() async throws {
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
        let task = Task {
            try await ComposerPasteboard.stage([text, NSItemProvider(object: image)], in: root)
        }
        await fulfillment(of: [started], timeout: TestReadiness.timeout)
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
        await fulfillment(of: [started], timeout: TestReadiness.timeout)
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

    func testComposerFocusUpdatesDoNotWriteBindingsDuringViewUpdates() async throws {
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

        // UIKit applies SwiftUI's focus after the update, so count echoes until it settles.
        func update(expectingFirstResponder expected: Bool, file: StaticString = #filePath, line: UInt = #line) async {
            isUpdating = true
            defer { isUpdating = false }
            host.rootView = input()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let settled = await TestReadiness.wait { view.isFirstResponder == expected }
            XCTAssertTrue(
                settled,
                "First responder never became \(expected). \(composerFocusDiagnostics(host, focused: focused))",
                file: file, line: line
            )
        }
        focused = false
        await update(expectingFirstResponder: false)
        XCTAssertEqual(writesDuringUpdate, 0, "SwiftUI-driven focus must not echo through its binding")

        focused = true
        await update(expectingFirstResponder: true)
        XCTAssertEqual(writesDuringUpdate, 0)

        enabled = false
        await update(expectingFirstResponder: false)
        XCTAssertTrue(focused, "Disabling input must preserve SwiftUI's requested focus")
        XCTAssertEqual(writesDuringUpdate, 0)

        enabled = true
        await update(expectingFirstResponder: true)
        XCTAssertTrue(view.resignFirstResponder())
        let blurred = await TestReadiness.wait { !focused }
        XCTAssertTrue(blurred, "User blur must still reach SwiftUI. \(composerFocusDiagnostics(host, focused: focused))")
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
        await fulfillment(of: [editing], timeout: TestReadiness.timeout)
        XCTAssertTrue(view.isFirstResponder)
        XCTAssertTrue(focused)
        XCTAssertEqual(view.text, body)
        view.smartInsertDeleteType = .no
        view.selectedRange = NSRange(location: 7, length: 0)
        view.paste(itemProviders: [NSItemProvider(object: pastedText as NSString)])
        await fulfillment(of: [attached], timeout: TestReadiness.timeout)
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
            if type == UTType.pdf.identifier { XCTAssertEqual(file.url.pathExtension, "pdf") }
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
        func pdfItem() -> NSItemProvider { item([(UTType.pdf.identifier, pdf)]) }
        func stage(
            _ attempts: [[NSItemProvider]], access: (UIPasteboard) throws -> Void
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

        let loaded = try await stage([[pdfItem()]]) { _ in }
        XCTAssertEqual(accessChecks, 0)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(loaded.files.first).url), pdf)
        AttachmentDraftStager.clean(loaded.files)

        let retried = try await stage([[refusedItem()], [pdfItem()]]) { _ in }
        XCTAssertEqual(accessChecks, 1)
        XCTAssertTrue(loads.isEmpty)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(retried.files.first).url), pdf)
        AttachmentDraftStager.clean(retried.files)

        do {
            _ = try await stage([[refusedItem()], [pdfItem()]]) { _ in throw ComposerPasteFailure.unreadable }
            XCTFail("A refused access check must not retry")
        } catch {
            XCTAssertEqual(error as? ComposerPasteFailure, .unreadable)
            XCTAssertEqual(accessChecks, 1)
            XCTAssertEqual(loads.count, 1, "The retry load must not run")
        }

        do {
            _ = try await stage([[pdfItem(), refusedItem()], [refusedItem()], [pdfItem()]]) { _ in }
            XCTFail("A failed retry must surface its error")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSItemProvider.errorDomain)
            XCTAssertEqual(accessChecks, 1)
            XCTAssertEqual(loads.count, 1, "Only one retry may run")
        }
        XCTAssertEqual(stagedFiles(), [], "Failed loads must not leave staged files")
    }

    func testPasteAndSaveSurfacesALocalStagingErrorWithoutCheckingAccess() async throws {
        let pdf = Data("%PDF-1.4".utf8)
        let board = clipboard(pdf, type: UTType.pdf.identifier)
        let root = stagingRoot()
        try Data().write(to: root)
        var loads = 0
        var accessChecks = 0
        do {
            _ = try await ComposerPasteboard.stageForSaving(
                from: board, in: root,
                providers: { _ in loads += 1; return [self.item([(UTType.pdf.identifier, pdf)])] },
                requestAccess: { _ in accessChecks += 1 })
            XCTFail("Staging under a file must fail")
        } catch {
            XCTAssertNotNil(error as? CocoaError, "\(error)")
        }
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(accessChecks, 0)
    }

    func testPasteAndSaveTreatsMissingProvidersAsARefusedLoad() async throws {
        let pdf = Data("%PDF-1.4".utf8)
        let board = clipboard(pdf, type: UTType.pdf.identifier)
        for missing in [[], [NSItemProvider()]] {
            var accessChecks = 0
            do {
                _ = try await ComposerPasteboard.stageForSaving(
                    from: board, in: stagingRoot(),
                    providers: { _ in missing },
                    requestAccess: { _ in accessChecks += 1 })
                XCTFail("A clipboard with content but no providers is unreadable")
            } catch {
                XCTAssertEqual(error as? ComposerPasteFailure, .unreadable, "\(missing)")
            }
            XCTAssertEqual(accessChecks, 1, "\(missing)")

            var loads = [missing, [item([(UTType.pdf.identifier, pdf)])]]
            accessChecks = 0
            let retried = try await ComposerPasteboard.stageForSaving(
                from: board, in: stagingRoot(),
                providers: { _ in loads.removeFirst() },
                requestAccess: { _ in accessChecks += 1 })
            XCTAssertEqual(accessChecks, 1, "\(missing)")
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(retried.files.first).url), pdf)
        }
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

    func testPasteAndSaveReadsEveryClipboardType() async throws {
        for type in [UTType.pdf.identifier, UTType.utf8PlainText.identifier, "com.example.custom"] {
            let board = clipboard(Data("content".utf8), type: type)
            let pasted = try await ComposerPasteboard.stageForSaving(from: board, in: stagingRoot())
            XCTAssertTrue(!pasted.text.isEmpty || !pasted.files.isEmpty, type)
        }
    }
}

private final class ProviderHandlerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.withLock { value += 1 }
    }

    var count: Int {
        lock.withLock { value }
    }
}

private final class CapturedFinish<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var finish: (@Sendable (() throws -> Value) -> Void)?

    func store(_ finish: @escaping @Sendable (() throws -> Value) -> Void) {
        lock.withLock { self.finish = finish }
    }

    func call(_ result: () throws -> Value) {
        let finish = lock.withLock { self.finish }
        finish?(result)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    func set() {
        lock.withLock { isSet = true }
    }

    var value: Bool {
        lock.withLock { isSet }
    }
}

/// Paths of every regular file under `directory`, relative to `base`.
private func regularFilePaths(under directory: URL, relativeTo base: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
        return []
    }
    var paths: [String] = []
    while let url = enumerator.nextObject() as? URL {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        let prefix = base.path + "/"
        paths.append(url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path)
    }
    return paths
}
