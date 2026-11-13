import Foundation
import SnipSnapCore
import SnipSnapPersistence
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import SnipSnapiOS

@MainActor
final class ShareExtensionDiagnosticsTests: XCTestCase {
    func testIntakeCopyFailureRecordsSafeLoadFailure() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = DiagnosticExtensionContext()
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            completion(URL(fileURLWithPath: "/nonexistent/private-snippet.png"), false, nil)
            return nil
        }
        let item = NSExtensionItem()
        item.attachments = [provider]
        context.items = [item]
        let events = ExtensionDiagnosticEvents()
        let model = ShareExtensionModel(extensionContext: context, sharedRootURL: root, diagnostics: events.recorder)
        await model.load()
        XCTAssertEqual(events.values.map(\.operation), ["share.extension_load"])
        XCTAssertEqual(events.values.first?.outcome, .failed)
        XCTAssertFalse(events.values.first!.line.contains("private-snippet"))
        guard case .failed = model.phase else { return XCTFail("Expected the visible intake failure") }
    }

    func testSaveFailureRecordsSafePublicationFailure() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let events = ExtensionDiagnosticEvents()
        let model = ShareExtensionModel(extensionContext: DiagnosticExtensionContext(), sharedRootURL: root,
            diagnostics: events.recorder, saveImport: { _ in throw CocoaError(.fileWriteNoPermission) })
        await model.load()
        model.content = "private snip"
        await model.save()
        XCTAssertEqual(events.values.map(\.operation), ["share.extension_save"])
        XCTAssertEqual(events.values.first?.errorCode, "cocoa.513")
    }

    func testStagingInitializationFailureDiffersFromUnavailableGroup() async throws {
        let events = ExtensionDiagnosticEvents()
        let model = ShareExtensionModel(extensionContext: DiagnosticExtensionContext(), sharedRootURL: temporaryRoot(),
            diagnostics: events.recorder, makeStaging: { _ in throw CocoaError(.fileWriteNoPermission) })
        await model.load()
        guard case .failed = model.phase else { return XCTFail("Expected staging failure") }
        XCTAssertEqual(events.values.map(\.operation), ["share.extension_startup"])
        XCTAssertEqual(events.values.first?.errorCode, "cocoa.513")
        let missing = ExtensionDiagnosticEvents()
        let unavailable = ShareExtensionModel(extensionContext: DiagnosticExtensionContext(), sharedRootURL: nil, diagnostics: missing.recorder)
        await unavailable.load()
        XCTAssertEqual(unavailable.phase, .unavailable)
        XCTAssertEqual(missing.values.first?.errorCode, "share.sharedContainerUnavailable")
    }

    func testExpectedCancellationIsQuietButUnrelatedDomainCodeIsFailure() async throws {
        let errors: [any Error] = [CancellationError(), CocoaError(.userCancelled), URLError(.cancelled),
            NSError(domain: "private.domain", code: NSUserCancelledError)]
        for error in errors {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let events = ExtensionDiagnosticEvents()
            let model = ShareExtensionModel(extensionContext: DiagnosticExtensionContext(), sharedRootURL: root,
                diagnostics: events.recorder, saveImport: { _ in throw error })
            await model.load()
            model.content = "private snip"
            await model.save()
            let unrelated = (error as NSError).domain == "private.domain"
            XCTAssertEqual(events.values.count, unrelated ? 1 : 0)
            XCTAssertEqual(model.canSave, !unrelated)
        }
    }

    func testProviderCancellationIsQuietAndUnrelatedDomainIsReported() async throws {
        let errors: [any Error] = [CocoaError(.userCancelled), URLError(.cancelled),
            NSError(domain: "private.domain", code: URLError.cancelled.rawValue)]
        for error in errors {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let context = DiagnosticExtensionContext()
            let provider = NSItemProvider()
            provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
                completion(nil, false, error)
                return nil
            }
            let item = NSExtensionItem()
            item.attachments = [provider]
            context.items = [item]
            let events = ExtensionDiagnosticEvents()
            let model = ShareExtensionModel(extensionContext: context, sharedRootURL: root, diagnostics: events.recorder)
            await model.load()
            let unrelated = (error as NSError).domain == "private.domain"
            XCTAssertEqual(events.values.count, unrelated ? 1 : 0)
            if unrelated {
                XCTAssertNil(context.cancellation)
                guard case .failed = model.phase else { return XCTFail("Real provider failure stays visible") }
            } else {
                _ = await TestReadiness.wait { context.cancellation != nil }
                XCTAssertNotEqual(model.phase, .loading, "Cancellation must settle the loading screen")
                XCTAssertEqual(context.cancellation?.domain, NSCocoaErrorDomain)
                XCTAssertEqual(context.cancellation?.code, NSUserCancelledError)
                XCTAssertFalse(context.completed)
                XCTAssertFalse(model.canSave)
            }
        }
    }

    func testCancelledLoadTaskIsQuiet() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let events = ExtensionDiagnosticEvents()
        let model = ShareExtensionModel(extensionContext: DiagnosticExtensionContext(), sharedRootURL: root, diagnostics: events.recorder)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.load()
        }
        await task.value
        XCTAssertTrue(events.values.isEmpty)
        XCTAssertFalse(model.canSave)
    }

    func testHealthyLoadAndSaveStayQuietAndComplete() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = DiagnosticExtensionContext()
        let events = ExtensionDiagnosticEvents()
        let model = ShareExtensionModel(extensionContext: context, sharedRootURL: root, diagnostics: events.recorder)
        await model.load()
        model.content = "private snip"
        await model.save()
        XCTAssertTrue(context.completed)
        XCTAssertTrue(events.values.isEmpty)
    }

    func testHealthySavePublishesAndCompletes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = DiagnosticExtensionContext()
        let model = ShareExtensionModel(extensionContext: context, sharedRootURL: root,
            diagnostics: ExtensionDiagnosticEvents().recorder)
        await model.load()
        model.content = "private snip"
        await model.save()
        XCTAssertNotEqual(model.phase, .saving)
        XCTAssertTrue(context.completed)
    }

    func testSaveFailureCancelledDuringFlushReturnsToEditing() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = DiagnosticExtensionContext()
        let cancelsSaveTask = AppDiagnosticRecorder { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let model = ShareExtensionModel(extensionContext: context, sharedRootURL: root,
            diagnostics: cancelsSaveTask, saveImport: { _ in throw CocoaError(.fileWriteNoPermission) })
        await model.load()
        model.content = "private snip"
        await Task { await model.save() }.value
        XCTAssertEqual(model.phase, .editing)
        XCTAssertFalse(context.completed)
    }

    func testSaveTaskCancelledAfterDurableSaveStaysPublishedWithoutCompleting() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = DiagnosticExtensionContext()
        let model = ShareExtensionModel(extensionContext: context, sharedRootURL: root,
            diagnostics: ExtensionDiagnosticEvents().recorder,
            saveImport: { _ in withUnsafeCurrentTask { $0?.cancel() } })
        await model.load()
        model.content = "private snip"
        await Task { await model.save() }.value
        XCTAssertNotEqual(model.phase, .saving)
        XCTAssertFalse(context.completed)
    }

    func testUserCancelDuringSaveCancelsRequest() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = DiagnosticExtensionContext()
        var model: ShareExtensionModel?
        model = ShareExtensionModel(extensionContext: context, sharedRootURL: root,
            diagnostics: ExtensionDiagnosticEvents().recorder, saveImport: { _ in model?.cancel() })
        let share = try XCTUnwrap(model)
        await share.load()
        share.content = "private snip"
        await share.save()
        _ = await TestReadiness.wait { context.cancellation != nil }
        XCTAssertEqual(share.phase, .cancelled)
        XCTAssertFalse(context.completed)
        XCTAssertEqual(context.cancellation?.code, NSUserCancelledError)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}

private final class ExtensionDiagnosticEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AppDiagnosticEvent] = []
    var values: [AppDiagnosticEvent] { lock.withLock { events } }
    var recorder: AppDiagnosticRecorder { AppDiagnosticRecorder { [self] event in lock.withLock { events.append(event) } } }
}

private final class DiagnosticExtensionContext: NSExtensionContext {
    var items: [NSExtensionItem] = []
    var completed = false
    var cancellation: NSError?
    override var inputItems: [Any] { items }
    override func cancelRequest(withError error: any Error) {
        cancellation = error as NSError
    }
    override func completeRequest(returningItems items: [Any]?, completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        completed = true
        completionHandler?(true)
    }
}
