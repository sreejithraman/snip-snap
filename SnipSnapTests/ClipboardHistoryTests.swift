import AppKit
import SnipSnapCore
import XCTest
@testable import SnipSnap
@testable import SnipSnapCloud
@testable import SnipSnapPersistence

private final class ClipboardDiagnosticProbe: @unchecked Sendable {
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

private final class ClipboardConversionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var holdsNextConversion = true
    private var heldConversion: CheckedContinuation<Void, Never>?

    var isHolding: Bool {
        lock.withLock { heldConversion != nil }
    }

    func convert(_ build: @escaping @Sendable () -> ClipboardEntry) async -> ClipboardEntry {
        await withCheckedContinuation { continuation in
            let holds = lock.withLock {
                guard holdsNextConversion else { return false }
                holdsNextConversion = false
                heldConversion = continuation
                return true
            }
            if !holds { continuation.resume() }
        }
        return build()
    }

    func release() {
        let continuation = lock.withLock {
            defer { heldConversion = nil }
            return heldConversion
        }
        continuation?.resume()
    }
}

@MainActor
private final class ClipboardSyncGenerationGate {
    private(set) var requestCount = 0
    private let heldRequests: Set<Int>
    private var held: [Int: CheckedContinuation<String?, any Error>] = [:]

    init(holding requests: Set<Int>) {
        heldRequests = requests
    }

    func generation() async throws -> String? {
        requestCount += 1
        let request = requestCount
        guard heldRequests.contains(request) else { return nil }
        return try await withCheckedThrowingContinuation { held[request] = $0 }
    }

    func isHolding(_ request: Int) -> Bool {
        held[request] != nil
    }

    func release(_ request: Int, throwing error: (any Error)? = nil) {
        guard let continuation = held.removeValue(forKey: request) else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: nil)
        }
    }
}

private struct ClipboardSyncTestFailure: Error {}

/// The saved-snips namespace key the app passes as the clipboard generation, for a new sync
/// generation in one account.
private func clipboardSyncGeneration(account: String = "account-A") -> String {
    let generation = UUID()
    let value = generation.uuidString.lowercased()
    let namespace = ICloudSyncNamespaceBinding(
        scope: "private",
        accountLineage: account,
        generation: generation,
        zones: [
            ICloudSyncZoneBinding(name: "snips-\(value)", ownerName: "_defaultOwner"),
            ICloudSyncZoneBinding(name: "payloads-\(value)", ownerName: "_defaultOwner"),
        ]
    )
    return SnipRecoveryScopeFactory.scope(forActiveCloudNamespace: namespace)!.rawValue
}

/// The sync generation the app reports; a test changes it to adopt a new one.
@MainActor
private final class ClipboardSyncGenerationSource {
    var current: String

    init(_ current: String) {
        self.current = current
    }

    func generation() async -> String? { current }
}

/// Holds the first upload, if asked, until the test resumes it; a cancelled run then uploads nothing.
private actor ClipboardHeldUploadCloud: ClipboardCloudTransport {
    private var snapshot = ClipboardCloudSnapshot()
    private var holdsNextSave: Bool
    private var heldSave: CheckedContinuation<Void, Never>?

    init(holdsFirstUpload: Bool = true) {
        holdsNextSave = holdsFirstUpload
    }

    var uploadedEntryIDs: Set<UUID> { Set(snapshot.entries.keys) }
    var uploadedTombstoneIDs: Set<UUID> { Set(snapshot.tombstones.keys) }

    /// Waits for the upload to be held. On timeout it stops holding, so no later upload hangs.
    func uploadHeld(within timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while heldSave == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if heldSave == nil { holdsNextSave = false }
        return heldSave != nil
    }

    func resumeUpload() {
        heldSave?.resume()
        heldSave = nil
    }

    func fetch() -> ClipboardCloudSnapshot { snapshot }

    func save(_ incoming: ClipboardCloudSnapshot, cancellation: ClipboardCloudCancellation) async throws {
        if holdsNextSave {
            holdsNextSave = false
            await withCheckedContinuation { heldSave = $0 }
        }
        try cancellation.check()
        snapshot = incoming
    }

    func deleteAll() { snapshot = ClipboardCloudSnapshot() }
}

/// Holds a step of a clipboard binding reset, fails one once, or holds a step and then fails it.
@MainActor
private final class ClipboardBindingResetGate {
    private var holdsStep: ClipboardBindingResetStep?
    private var failsStep: ClipboardBindingResetStep?
    private var heldStep: CheckedContinuation<Void, Never>?

    init(holding step: ClipboardBindingResetStep? = nil, failingOnce failure: ClipboardBindingResetStep? = nil) {
        holdsStep = step
        failsStep = failure
    }

    func reach(_ step: ClipboardBindingResetStep) async throws {
        if step == holdsStep {
            holdsStep = nil
            await withCheckedContinuation { heldStep = $0 }
        }
        if step == failsStep {
            failsStep = nil
            throw ClipboardSyncTestFailure()
        }
    }

    /// Waits for the step to be held. On timeout it stops holding, so no later reset hangs.
    func stepHeld(within timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while heldStep == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if heldStep == nil { holdsStep = nil }
        return heldStep != nil
    }

    func release() {
        heldStep?.resume()
        heldStep = nil
    }
}

/// A history synced under its first sync generation, whose app now reports the second.
private struct ClipboardGenerationFixture {
    let history: ClipboardHistory
    let pasteboard: NSPasteboard
    let historyDirectory: URL
    let bindingURL: URL
    let firstGeneration: String
    let secondGeneration: String
    let secondCloud: ClipboardHeldUploadCloud
    let generationSource: ClipboardSyncGenerationSource
}

@MainActor
final class ClipboardHistoryTests: XCTestCase {
    func testCapturesAndRestoresEveryPasteboardItem() throws {
        let context = try makeContext()
        let firstURL = URL(fileURLWithPath: "/tmp/first.md")
        let secondURL = URL(fileURLWithPath: "/tmp/second.md")
        writeFileURLs([firstURL, secondURL], to: context.pasteboard)

        context.history.poll()

        let entry = try XCTUnwrap(context.history.entries.first)
        XCTAssertEqual(entry.items.count, 2)
        XCTAssertEqual(entry.fileURLs, [firstURL, secondURL])

        context.pasteboard.clearContents()
        XCTAssertTrue(context.pasteboard.setString("replacement", forType: .string))
        XCTAssertTrue(context.history.restore(entry))
        XCTAssertEqual(context.pasteboard.pasteboardItems?.count, 2)
        XCTAssertEqual(
            context.pasteboard.pasteboardItems?.compactMap { $0.string(forType: .fileURL) },
            [firstURL.absoluteString, secondURL.absoluteString]
        )
    }

    func testCaptureRestoresSourceSpecificPasteboardForms() throws {
        let context = try makeContext()
        let customType = NSPasteboard.PasteboardType.rtf
        let item = NSPasteboardItem()
        item.setString("Visible text", forType: .string)
        item.setData(Data([0x01, 0x02, 0x03]), forType: customType)
        context.pasteboard.clearContents()
        XCTAssertTrue(context.pasteboard.writeObjects([item]))

        context.history.poll()
        let entry = try XCTUnwrap(context.history.entries.first)
        context.pasteboard.clearContents()

        XCTAssertTrue(context.history.restore(entry))
        XCTAssertEqual(
            context.pasteboard.data(forType: customType),
            Data([0x01, 0x02, 0x03])
        )
    }

    func testRestoreDoesNotReplaceStoredRTFWhenFilesArePresent() throws {
        let context = try makeContext()
        let directory = context.storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("formatted-history.txt")
        try Data("Attachment".utf8).write(to: source)
        let font = NSFont.boldSystemFont(ofSize: 18)
        let attributed = NSAttributedString(
            string: "Bold text",
            attributes: [.font: font]
        )
        let rtf = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let primary = NSPasteboardItem()
        primary.setString("Bold text", forType: .string)
        primary.setData(rtf, forType: .rtf)
        context.pasteboard.clearContents()
        XCTAssertTrue(context.pasteboard.writeObjects([primary, source as NSURL]))

        context.history.poll()
        let entry = try XCTUnwrap(context.history.entries.first)
        XCTAssertTrue(context.history.restore(entry))
        XCTAssertEqual(context.pasteboard.data(forType: .rtf), rtf)
        XCTAssertNotNil(context.pasteboard.data(forType: .rtfd))

        let target = NSTextView()
        target.isRichText = true
        target.importsGraphics = true
        XCTAssertTrue(target.readSelection(from: context.pasteboard))
        let restoredFont = try XCTUnwrap(target.textStorage?.attribute(
            .font,
            at: 0,
            effectiveRange: nil
        ) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: restoredFont).contains(.boldFontMask))
    }

    func testCaptureRestoresMixedSnipRichText() async throws {
        let context = try makeContext()
        let directory = context.storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("mixed-history.txt")
        try Data("Attachment".utf8).write(to: source)
        let writers = SnipPasteboardExport(
            text: "Keep this text",
            attachmentURLs: [source]
        ).pasteboardWriters()
        context.pasteboard.clearContents()
        XCTAssertTrue(context.pasteboard.writeObjects(writers))

        context.history.poll()
        await context.history.waitForPendingCapture()
        let entry = try XCTUnwrap(context.history.entries.first)
        XCTAssertEqual(entry.plainText, "Keep this text")
        XCTAssertTrue(context.history.restore(entry))

        let target = NSTextView()
        target.isRichText = true
        target.importsGraphics = true
        XCTAssertTrue(target.readSelection(from: context.pasteboard))
        XCTAssertTrue(target.string.contains("Keep this text"))
        var attachmentCount = 0
        target.textStorage?.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: target.textStorage?.length ?? 0)
        ) { value, _, _ in
            if value != nil {
                attachmentCount += 1
            }
        }
        XCTAssertEqual(attachmentCount, 1)
    }

    func testRestoreRebuildsMixedRichTextDroppedByTheHistoryLimit() async throws {
        let context = try makeContext()
        let directory = context.storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("large-mixed-history.bin")
        try Data(
            repeating: 7,
            count: ClipboardHistoryState.representationByteLimit + 1
        ).write(to: source)
        let writers = SnipPasteboardExport(
            text: "Keep this large text",
            attachmentURLs: [source]
        ).pasteboardWriters()
        context.pasteboard.clearContents()
        XCTAssertTrue(context.pasteboard.writeObjects(writers))

        context.history.poll()
        await context.history.waitForPendingCapture()
        let entry = try XCTUnwrap(context.history.entries.first)
        XCTAssertFalse(entry.items.flatMap(\.representations).contains {
            $0.type == NSPasteboard.PasteboardType.rtfd.rawValue
        })
        XCTAssertTrue(context.history.restore(entry))

        let target = NSTextView()
        target.isRichText = true
        target.importsGraphics = true
        XCTAssertTrue(target.readSelection(from: context.pasteboard))
        XCTAssertTrue(target.string.contains("Keep this large text"))
        var attachmentCount = 0
        target.textStorage?.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: target.textStorage?.length ?? 0)
        ) { value, _, _ in
            if value != nil {
                attachmentCount += 1
            }
        }
        XCTAssertEqual(attachmentCount, 1)
    }

    func testRestoreRebuildsMixedRichTextFromTheReadableFiles() throws {
        let context = try makeContext()
        let directory = context.storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let readable = directory.appendingPathComponent("readable-history.txt")
        let missing = directory.appendingPathComponent("missing-history.txt")
        try Data("Attachment".utf8).write(to: readable)
        let primary = NSPasteboardItem()
        primary.setString("Keep partial text", forType: .string)
        context.pasteboard.clearContents()
        XCTAssertTrue(context.pasteboard.writeObjects([
            primary,
            readable as NSURL,
            missing as NSURL
        ]))

        context.history.poll()
        let entry = try XCTUnwrap(context.history.entries.first)
        XCTAssertEqual(entry.fileURLs, [readable, missing])
        XCTAssertTrue(context.history.restore(entry))

        let target = NSTextView()
        target.isRichText = true
        target.importsGraphics = true
        XCTAssertTrue(target.readSelection(from: context.pasteboard))
        XCTAssertTrue(target.string.contains("Keep partial text"))
        var attachmentCount = 0
        target.textStorage?.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: target.textStorage?.length ?? 0)
        ) { value, _, _ in
            if value != nil {
                attachmentCount += 1
            }
        }
        XCTAssertEqual(attachmentCount, 1)
    }

    func testRestoreDoesNotRepeatOtherTextItemsInRebuiltRichText() throws {
        let context = try makeContext()
        let directory = context.storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("multi-text-history.txt")
        try Data("Attachment".utf8).write(to: source)
        let first = NSPasteboardItem()
        first.setString("First", forType: .string)
        let second = NSPasteboardItem()
        second.setString("Second", forType: .string)
        context.pasteboard.clearContents()
        XCTAssertTrue(context.pasteboard.writeObjects([first, second, source as NSURL]))

        context.history.poll()
        let entry = try XCTUnwrap(context.history.entries.first)
        XCTAssertTrue(context.history.restore(entry))

        let restored = try XCTUnwrap(context.pasteboard.pasteboardItems)
        XCTAssertEqual(restored.compactMap { $0.string(forType: .string) }, ["First", "Second"])
        let data = try XCTUnwrap(restored[0].data(forType: .rtfd))
        let richText = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        )
        XCTAssertFalse(richText.string.contains("Second"))
    }

    func testRestoreRebuildsRTFDFromStoredRTFOrHTMLText() throws {
        let context = try makeContext()
        let directory = context.storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("formatted-only-history.txt")
        try Data("Attachment".utf8).write(to: source)
        let attributed = NSAttributedString(string: "Formatted only")

        for (pasteboardType, documentType) in [
            (NSPasteboard.PasteboardType.rtf, NSAttributedString.DocumentType.rtf),
            (.html, .html)
        ] {
            let data = try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: documentType]
            )
            let item = NSPasteboardItem()
            item.setData(data, forType: pasteboardType)
            context.pasteboard.clearContents()
            XCTAssertTrue(context.pasteboard.writeObjects([item, source as NSURL]))

            context.history.poll()
            let entry = try XCTUnwrap(context.history.entries.first)
            XCTAssertTrue(context.history.restore(entry))
            XCTAssertEqual(context.pasteboard.data(forType: pasteboardType), data)
            let rtfd = try XCTUnwrap(context.pasteboard.data(forType: .rtfd))
            let rebuilt = try NSAttributedString(
                data: rtfd,
                options: [.documentType: NSAttributedString.DocumentType.rtfd],
                documentAttributes: nil
            )
            XCTAssertTrue(rebuilt.string.contains("Formatted only"))
        }
    }

    func testCaptureExtractsTextFromAnRTFDOnlyItem() async throws {
        let context = try makeContext()
        let directory = context.storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("rtfd-only.txt")
        try Data("Attachment".utf8).write(to: source)
        let exportItem = try XCTUnwrap(
            SnipPasteboardExport(
                text: "Searchable text",
                attachmentURLs: [source]
            ).pasteboardWriters().first as? NSPasteboardItem
        )
        let richData = try XCTUnwrap(exportItem.data(forType: .rtfd))
        let richItem = NSPasteboardItem()
        richItem.setData(richData, forType: .rtfd)
        context.pasteboard.clearContents()
        XCTAssertTrue(context.pasteboard.writeObjects([richItem]))

        context.history.poll()
        await context.history.waitForPendingCapture()

        XCTAssertEqual(context.history.entries.first?.plainText, "Searchable text\n")
        XCTAssertTrue(context.history.entries.first?.searchText.contains("Searchable text") == true)
    }

    func testRTFDTextExtractionKeepsLineBreakBeforeAnInterleavedAttachment() async throws {
        let context = try makeContext()
        let richText = NSMutableAttributedString(string: "before\n")
        let attachment = NSTextAttachment(data: Data([1]), ofType: "public.data")
        richText.append(NSAttributedString(attachment: attachment))
        richText.append(NSAttributedString(string: "after"))
        let data = try richText.data(
            from: NSRange(location: 0, length: richText.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        let item = NSPasteboardItem()
        item.setData(data, forType: .rtfd)
        context.pasteboard.clearContents()
        XCTAssertTrue(context.pasteboard.writeObjects([item]))

        context.history.poll()
        await context.history.waitForPendingCapture()

        XCTAssertEqual(context.history.entries.first?.plainText, "before\nafter")
    }

    func testCaptureSkipsUnsupportedAndOversizedRepresentations() throws {
        let context = try makeContext()
        let item = NSPasteboardItem()
        item.setString("Visible text", forType: .string)
        item.setData(
            Data(repeating: 7, count: ClipboardHistoryState.representationByteLimit + 1),
            forType: .png
        )
        item.setData(Data([1, 2, 3]), forType: .init("world.sree.snipsnap.tests.unsupported"))
        context.pasteboard.clearContents()
        XCTAssertTrue(context.pasteboard.writeObjects([item]))

        context.history.poll()

        let entry = try XCTUnwrap(context.history.entries.first)
        XCTAssertEqual(entry.items.flatMap(\.representations).map(\.type), [NSPasteboard.PasteboardType.string.rawValue])
    }

    func testLargeCaptureFinishesThroughTheBackgroundProcessingPath() async throws {
        let context = try makeContext()
        let item = NSPasteboardItem()
        item.setString("Large image", forType: .string)
        item.setData(
            Data(repeating: 7, count: ClipboardHistory.backgroundProcessingThreshold),
            forType: .png
        )
        context.pasteboard.clearContents()
        XCTAssertTrue(context.pasteboard.writeObjects([item]))

        context.history.poll()
        await context.history.waitForPendingCapture()

        let entry = try XCTUnwrap(context.history.entries.first)
        XCTAssertEqual(entry.text, "Large image")
        XCTAssertEqual(entry.imageRepresentations.first?.data.count, ClipboardHistory.backgroundProcessingThreshold)
    }

    func testPauseAndScopedSuppressionSkipChanges() throws {
        let context = try makeContext()
        writeText("Initial", to: context.pasteboard)
        context.history.poll()
        XCTAssertEqual(context.history.entries.map(\.text), ["Initial"])

        context.history.setPaused(true)
        writeText("While paused", to: context.pasteboard)
        context.history.poll()
        context.history.setPaused(false)
        context.history.poll()
        XCTAssertEqual(context.history.entries.map(\.text), ["Initial"])

        let token = context.history.beginSuppression()
        writeText("Temporary copy", to: context.pasteboard)
        context.history.poll()
        context.history.endSuppression(token)
        context.history.poll()
        XCTAssertEqual(context.history.entries.map(\.text), ["Initial"])

        writeText("User copy", to: context.pasteboard)
        context.history.poll()
        XCTAssertEqual(context.history.entries.map(\.text), ["User copy", "Initial"])
    }

    func testPausingDuringGeneralBoardConversionAdmitsNothing() async throws {
        let gate = ClipboardConversionGate()
        let context = try makeContext(capture: (generalPasteboard: true, conversion: gate.convert))
        writeText("Copied before pause", to: context.pasteboard)

        context.history.poll()
        try await waitUntil { gate.isHolding }
        context.history.setPaused(true)
        gate.release()
        await context.history.flushPersistence()

        context.history.setPaused(false)
        writeText("Copied after resume", to: context.pasteboard)
        context.history.poll()
        await context.history.waitForPendingCapture()
        XCTAssertEqual(context.history.entries.map(\.text), ["Copied after resume"])
    }

    func testSuppressingDuringGeneralBoardConversionAdmitsNothing() async throws {
        let gate = ClipboardConversionGate()
        let context = try makeContext(capture: (generalPasteboard: true, conversion: gate.convert))
        writeText("Copied before suppression", to: context.pasteboard)

        context.history.poll()
        try await waitUntil { gate.isHolding }
        let token = context.history.beginSuppression()
        gate.release()
        await context.history.flushPersistence()

        context.history.endSuppression(token)
        writeText("Copied after suppression", to: context.pasteboard)
        context.history.poll()
        await context.history.waitForPendingCapture()
        XCTAssertEqual(context.history.entries.map(\.text), ["Copied after suppression"])
    }

    func testPausingOrSuppressingBeforeTheGeneralBoardReadAdmitsNothing() async throws {
        let context = try makeContext(capture: (generalPasteboard: true, conversion: { build in build() }))
        writeText("Copied before pause", to: context.pasteboard)
        context.history.poll()
        context.history.setPaused(true)
        await context.history.flushPersistence()
        context.history.setPaused(false)

        writeText("Copied before suppression", to: context.pasteboard)
        context.history.poll()
        let token = context.history.beginSuppression()
        await context.history.flushPersistence()
        context.history.endSuppression(token)

        XCTAssertTrue(context.history.entries.isEmpty)
    }

    func testClearingBeforeTheGeneralBoardReadKeepsTheCopyForTheNextPoll() async throws {
        let gate = ClipboardConversionGate()
        let context = try makeContext(
            persistedEntries: [clipboardEntry("Earlier")],
            capture: (generalPasteboard: true, conversion: gate.convert)
        )
        await context.history.flushPersistence()
        writeText("Copied during clear", to: context.pasteboard)

        context.history.poll()
        context.history.clear()
        context.history.poll()
        try await waitUntil { gate.isHolding && context.history.entries.isEmpty }
        gate.release()
        await context.history.flushPersistence()

        XCTAssertEqual(context.history.entries.map(\.text), ["Copied during clear"])
    }

    func testPausingDuringLargeCaptureConversionAdmitsNothing() async throws {
        let gate = ClipboardConversionGate()
        let context = try makeContext(capture: (generalPasteboard: false, conversion: gate.convert))
        let item = NSPasteboardItem()
        item.setString("Large private image", forType: .string)
        item.setData(
            Data(repeating: 7, count: ClipboardHistory.backgroundProcessingThreshold),
            forType: .png
        )
        context.pasteboard.clearContents()
        XCTAssertTrue(context.pasteboard.writeObjects([item]))

        context.history.poll()
        try await waitUntil { gate.isHolding }
        context.history.setPaused(true)
        gate.release()
        await context.history.flushPersistence()

        XCTAssertTrue(context.history.entries.isEmpty)
    }

    func testDisablingSyncDuringASuspendedRunEndsItAtOnce() async throws {
        let gate = ClipboardSyncGenerationGate(holding: [1, 2])
        let history = try makeSyncedHistory(gate)
        history.setSyncEnabled(true)
        let stoppedRun = Task { await history.syncNow() }
        try await waitUntil { gate.isHolding(1) }
        XCTAssertTrue(history.isSyncing)

        history.setSyncEnabled(false)
        XCTAssertFalse(history.isSyncing)

        history.setSyncEnabled(true)
        let nextRun = Task { await history.syncNow() }
        try await waitUntil { gate.isHolding(2) }
        let previewRevision = history.filePreviewRevision
        gate.release(1, throwing: ClipboardSyncTestFailure())
        await stoppedRun.value
        XCTAssertTrue(history.isSyncing)
        XCTAssertNil(history.syncError)
        XCTAssertEqual(history.filePreviewRevision, previewRevision)

        gate.release(2)
        await nextRun.value
        XCTAssertFalse(history.isSyncing)
    }

    func testStoppedSyncRequestDoesNotReleaseTheNewerRequest() async throws {
        let gate = ClipboardSyncGenerationGate(holding: [1, 2])
        let history = try makeSyncedHistory(gate)
        history.setSyncEnabled(true)
        try await waitUntil { gate.isHolding(1) }

        history.stopSync()
        history.requestSync()
        gate.release(1)
        try await waitUntil { gate.isHolding(2) }
        history.requestSync()
        gate.release(2)
        // A third run could start only after the 300 ms debounce; the wait ends early if one does.
        try await waitUntil(timeout: .seconds(3), reportingTimeout: false) { gate.requestCount > 2 }

        XCTAssertEqual(gate.requestCount, 2)
    }

    func testTurningICloudSyncOffFromTheStaleCopyAlertStopsTheUploadInFlight() async throws {
        let cloud = ClipboardHeldUploadCloud()
        let (disableFinished, finishDisable) = AsyncStream<Void>.makeStream()
        let settings = SyncedContentSettingsModel(
            mode: .iCloudSync,
            initialState: .failed(.iCloudUnavailable),
            disableAction: { _ in for await _ in disableFinished {} }
        )
        let context = try makeContext()
        let history = context.history
        let syncRoot = context.storeURL.deletingLastPathComponent()
            .appendingPathComponent("SyncMode", isDirectory: true)
        let service = ClipboardCloudSyncService(store: history.sharedStore, syncRootURL: syncRoot,
                                                makeTransport: { _ in cloud })
        history.configureSync(
            containerIdentifier: "iCloud.org.example.snipsnap",
            rootURL: syncRoot,
            // As SnipSnapApp wires it.
            mainEnabled: {
                guard settings.mode == .iCloudSync else { return false }
                switch settings.state {
                case .disabling, .deleting: return false
                default: return true
                }
            },
            generation: { "account-generation-A" },
            makeCloudService: { _, _, _ in service }
        )
        try await history.sharedStore.insert(clipboardEntry("stays local"))
        history.setSyncEnabled(true)
        let run = Task { await history.syncNow() }
        let uploadHeld = await cloud.uploadHeld()
        XCTAssertTrue(uploadHeld, "The upload never started")

        // The alert's Turn off sync button.
        let disabling = Task.immediate { await settings.disableICloudSync(.useCurrentCache) }
        try await waitUntil { !service.isSyncing }
        await cloud.resumeUpload()
        await run.value

        let uploaded = await cloud.uploadedEntryIDs
        XCTAssertEqual(uploaded, [])
        XCTAssertNil(history.syncError)
        finishDisable.finish()
        await disabling.value
    }

    func testSyncSetsAsideHistoryAndFollowsANewSyncGeneration() async throws {
        let diagnostics = ClipboardDiagnosticProbe()
        let older = clipboardEntry("first generation")
        let fixture = try await makeHistoryAdoptingANewSyncGeneration(
            syncing: [older], diagnostics: diagnostics.recorder
        )
        let history = fixture.history
        await history.syncNow()

        XCTAssertNil(history.syncError)
        XCTAssertFalse(history.entries.contains { $0.id == older.id })
        let setAside = try await onlySetAsideHistory(in: fixture)
        XCTAssertEqual(setAside.entries.map(\.id), [older.id])

        let newer = try await capture("second generation", in: fixture)
        history.stopSync()
        await history.syncNow()

        let secondUpload = await fixture.secondCloud.uploadedEntryIDs
        XCTAssertEqual(secondUpload, [newer.id])
        XCTAssertNil(history.syncError)
        XCTAssertEqual(diagnostics.events.map(\.operation), [])
    }

    func testWritesDuringTheSetAsideKeepOldHistoryOutOfTheNewSyncGeneration() async throws {
        let copied = clipboardEntry("copied again")
        let deleted = clipboardEntry("deleted")
        let oldIDs: Set<UUID> = [copied.id, deleted.id]
        let gate = ClipboardBindingResetGate(holding: .historyCleared)
        let fixture = try await makeHistoryAdoptingANewSyncGeneration(
            syncing: [copied, deleted], resetStep: { try await gate.reach($0) }
        )
        let history = fixture.history
        let run = Task { await history.syncNow() }
        let held = await gate.stepHeld()
        XCTAssertTrue(held, "The set-aside never cleared the stored history")
        XCTAssertFalse(history.entries.contains { oldIDs.contains($0.id) })

        history.delete(id: deleted.id)
        XCTAssertTrue(history.restore(copied))
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "copied again")
        let snapshot = Task { try await history.checkedCLISnapshot() }
        // Lets the snapshot request its turn before the reset resumes.
        for _ in 0..<5 { await Task.yield() }
        gate.release()
        await run.value
        let snapshotEntries = try await snapshot.value
        await history.flushPersistence()
        history.stopSync()

        XCTAssertFalse(snapshotEntries.contains { oldIDs.contains($0.id) })
        let uploaded = await fixture.secondCloud.uploadedEntryIDs
        let uploadedTombstones = await fixture.secondCloud.uploadedTombstoneIDs
        XCTAssertTrue(uploaded.isDisjoint(with: oldIDs))
        XCTAssertTrue(uploadedTombstones.isDisjoint(with: oldIDs))
        let stored = try await history.sharedStore.load()
        XCTAssertFalse(stored.entries.contains { oldIDs.contains($0.id) })
        XCTAssertFalse(history.entries.contains { oldIDs.contains($0.id) })
        XCTAssertNil(history.syncError)
    }

    func testSetAsideFailureAfterRemovingTheBindingKeepsOldHistoryOutOfTheNewSyncGeneration() async throws {
        let first = clipboardEntry("first")
        let second = clipboardEntry("second")
        let oldIDs: Set<UUID> = [first.id, second.id]
        let gate = ClipboardBindingResetGate(holding: .bindingRemoved, failingOnce: .bindingRemoved)
        let fixture = try await makeHistoryAdoptingANewSyncGeneration(
            syncing: [first, second], resetStep: { try await gate.reach($0) }
        )
        let history = fixture.history
        let run = Task { await history.syncNow() }
        let held = await gate.stepHeld()
        XCTAssertTrue(held, "The set-aside never removed the binding")
        // An unreadable store also fails the reload after the failed reset.
        let storeURL = history.sharedStore.url
        try FileManager.default.removeItem(at: storeURL)
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: false)
        XCTAssertTrue(history.restore(first))
        gate.release()
        await run.value

        XCTAssertFalse(history.entries.contains { oldIDs.contains($0.id) })
        XCTAssertNotNil(history.syncError)
        try FileManager.default.removeItem(at: storeURL)
        await history.flushPersistence()
        let stored = try await history.sharedStore.load()
        XCTAssertFalse(stored.entries.contains { oldIDs.contains($0.id) })
        let uploadedAfterFailure = await fixture.secondCloud.uploadedEntryIDs
        XCTAssertEqual(uploadedAfterFailure, [])

        let newer = try await capture("second generation", in: fixture)
        history.stopSync()
        await history.syncNow()

        let uploaded = await fixture.secondCloud.uploadedEntryIDs
        XCTAssertEqual(uploaded, [newer.id])
        XCTAssertNil(history.syncError)
    }

    func testSetAsideFailureBeforeRemovingTheBindingSetsAsideAgainOnTheNextSync() async throws {
        let older = clipboardEntry("first generation")
        let gate = ClipboardBindingResetGate(failingOnce: .historyCleared)
        let fixture = try await makeHistoryAdoptingANewSyncGeneration(
            syncing: [older], resetStep: { try await gate.reach($0) }
        )
        let history = fixture.history
        await history.syncNow()

        XCTAssertFalse(history.entries.contains { $0.id == older.id })
        XCTAssertNotNil(history.syncError)
        XCTAssertEqual(try Data(contentsOf: fixture.bindingURL), try JSONEncoder().encode(fixture.firstGeneration))

        history.stopSync()
        await history.syncNow()

        XCTAssertNil(history.syncError)
        XCTAssertEqual(try Data(contentsOf: fixture.bindingURL), try JSONEncoder().encode(fixture.secondGeneration))
        let uploaded = await fixture.secondCloud.uploadedEntryIDs
        XCTAssertEqual(uploaded, [])
    }

    func testWritesAdmittedBeforeTheSetAsideFinishFirstAndStayOutOfTheNewSyncGeneration() async throws {
        let pinned = clipboardEntry("pinned before the set-aside")
        let read = clipboardEntry("read before the set-aside")
        let oldIDs: Set<UUID> = [pinned.id, read.id]
        let fixture = try await makeHistoryAdoptingANewSyncGeneration(syncing: [pinned, read])
        let history = fixture.history

        // Each call takes its turn in the history queue before the next line runs, so the pin and
        // the read are queued and unstarted when the set-aside takes its turn.
        let pin = Task.immediate { await history.togglePinned(id: pinned.id) }
        let snapshot = Task.immediate { try await history.checkedCLISnapshot() }
        let reset = Task.immediate { await history.resetCloudAccount() }
        await pin.value
        let snapshotEntries = try await snapshot.value
        await reset.value

        XCTAssertEqual(Set(snapshotEntries.map(\.id)), oldIDs)
        let setAside = try await onlySetAsideHistory(in: fixture)
        XCTAssertEqual(Set(setAside.entries.map(\.id)), oldIDs)
        XCTAssertEqual(setAside.entries.first { $0.id == pinned.id }?.isPinned, true)
        XCTAssertFalse(history.entries.contains { oldIDs.contains($0.id) })
        XCTAssertNil(history.syncError)
        XCTAssertNil(history.persistenceError)

        history.stopSync()
        await history.syncNow()
        await history.flushPersistence()
        history.stopSync()

        XCTAssertEqual(try Data(contentsOf: fixture.bindingURL), try JSONEncoder().encode(fixture.secondGeneration))
        let uploaded = await fixture.secondCloud.uploadedEntryIDs
        let uploadedTombstones = await fixture.secondCloud.uploadedTombstoneIDs
        XCTAssertTrue(uploaded.isDisjoint(with: oldIDs))
        XCTAssertTrue(uploadedTombstones.isDisjoint(with: oldIDs))
        let stored = try await history.sharedStore.load()
        XCTAssertFalse(stored.entries.contains { oldIDs.contains($0.id) })
        XCTAssertNil(history.syncError)
    }

    func testAccountResetWithoutAClipboardBindingKeepsAnEditMadeDuringIt() async throws {
        let kept = clipboardEntry("kept")
        let deleted = clipboardEntry("deleted")
        let context = try makeContext(persistedEntries: [kept, deleted])
        let history = context.history
        let syncRoot = context.storeURL.deletingLastPathComponent()
            .appendingPathComponent("SyncMode", isDirectory: true)
        let service = ClipboardCloudSyncService(
            store: history.sharedStore, syncRootURL: syncRoot,
            makeTransport: { _ in ClipboardHeldUploadCloud(holdsFirstUpload: false) }
        )
        history.configureSync(
            containerIdentifier: "iCloud.org.example.snipsnap",
            rootURL: syncRoot,
            mainEnabled: { true },
            generation: { nil },
            makeCloudService: { _, _, _ in service }
        )
        await history.flushPersistence()
        XCTAssertEqual(Set(history.entries.map(\.id)), [kept.id, deleted.id])

        // The reset suspends before its turn in the history queue, so the delete lands first.
        let reset = Task.immediate { await history.resetCloudAccount() }
        history.delete(id: deleted.id)
        await reset.value
        await history.flushPersistence()

        XCTAssertEqual(history.entries.map(\.id), [kept.id])
        let stored = try await history.sharedStore.load()
        XCTAssertEqual(stored.entries.map(\.id), [kept.id])
        XCTAssertNotNil(stored.tombstones[deleted.id])
        XCTAssertNil(history.syncError)
    }

    func testCopyDuringTheSetAsideIsRecordedInTheNewHistory() async throws {
        let older = clipboardEntry("first generation")
        let copiedText = "copied during the set-aside"
        let gate = ClipboardBindingResetGate(holding: .historyCleared)
        let fixture = try await makeHistoryAdoptingANewSyncGeneration(
            syncing: [older], resetStep: { try await gate.reach($0) }
        )
        let history = fixture.history
        let run = Task { await history.syncNow() }
        let held = await gate.stepHeld()
        XCTAssertTrue(held, "The set-aside never cleared the stored history")

        writeText(copiedText, to: fixture.pasteboard)
        history.poll()
        gate.release()
        await run.value
        history.poll()
        await history.flushPersistence()
        history.stopSync()

        let copies = history.entries.filter { $0.text == copiedText }
        XCTAssertEqual(copies.count, 1)
        let copy = try XCTUnwrap(copies.first)
        let stored = try await history.sharedStore.load()
        XCTAssertTrue(stored.entries.contains { $0.id == copy.id })
        let setAside = try await onlySetAsideHistory(in: fixture)
        XCTAssertEqual(setAside.entries.map(\.id), [older.id])
        XCTAssertNil(history.syncError)

        await history.syncNow()
        let uploaded = await fixture.secondCloud.uploadedEntryIDs
        XCTAssertTrue(uploaded.contains(copy.id))
        XCTAssertFalse(uploaded.contains(older.id))
    }

    func testCopyOfASetAsideEntryDuringTheSetAsideIsNotRecapturedIntoTheNewHistory() async throws {
        let olderText = "first generation"
        let older = clipboardEntry(olderText)
        let gate = ClipboardBindingResetGate(holding: .historyCleared)
        let fixture = try await makeHistoryAdoptingANewSyncGeneration(
            syncing: [older], resetStep: { try await gate.reach($0) }
        )
        let history = fixture.history
        let run = Task { await history.syncNow() }
        let held = await gate.stepHeld()
        XCTAssertTrue(held, "The set-aside never cleared the stored history")

        XCTAssertTrue(history.restore(older))
        history.poll()
        gate.release()
        await run.value
        history.poll()
        await history.flushPersistence()
        history.stopSync()

        XCTAssertFalse(history.entries.contains { $0.text == olderText })
        let stored = try await history.sharedStore.load()
        XCTAssertFalse(stored.entries.contains { $0.text == olderText })
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), olderText)

        await history.syncNow()
        let uploaded = await fixture.secondCloud.uploadedEntryIDs
        let uploadedTombstones = await fixture.secondCloud.uploadedTombstoneIDs
        let storedAfterSync = try await history.sharedStore.load()
        XCTAssertTrue(uploaded.allSatisfy { id in
            storedAfterSync.entries.contains { $0.id == id && $0.text != olderText }
        })
        XCTAssertFalse(uploadedTombstones.contains(older.id))
    }

    func testAccountResetDropsCopiesStillWaitingForASetAside() async throws {
        for setAsideFails in [false, true] {
            let older = clipboardEntry("first generation")
            let copiedText = "copied before the account reset"
            let variant = setAsideFails ? "failed set-aside" : "successful set-aside"
            let gate = ClipboardBindingResetGate(
                holding: .historyCleared, failingOnce: setAsideFails ? .historyCleared : nil
            )
            let fixture = try await makeHistoryAdoptingANewSyncGeneration(
                syncing: [older], resetStep: { try await gate.reach($0) }
            )
            let history = fixture.history
            let run = Task { await history.syncNow() }
            let held = await gate.stepHeld()
            XCTAssertTrue(held, "The set-aside never cleared the stored history")

            writeText(copiedText, to: fixture.pasteboard)
            history.poll()
            XCTAssertTrue(history.isSyncing)
            let reset = Task { await history.resetCloudAccount() }
            // The account reset stops the sync run, then queues its set-aside in the same turn.
            try await waitUntil { !history.isSyncing }
            gate.release()
            await run.value
            await reset.value
            await history.flushPersistence()
            history.stopSync()

            XCTAssertFalse(history.entries.contains { $0.text == copiedText }, variant)
            let stored = try await history.sharedStore.load()
            XCTAssertFalse(stored.entries.contains { $0.text == copiedText }, variant)
            let setAside = try await setAsideHistories(in: fixture)
            XCTAssertFalse(setAside.contains { $0.entries.contains { $0.text == copiedText } }, variant)

            fixture.generationSource.current = clipboardSyncGeneration(account: "account-B")
            await history.syncNow()
            history.stopSync()

            XCTAssertEqual(history.entries, [], variant)
            let uploaded = await fixture.secondCloud.uploadedEntryIDs
            let uploadedTombstones = await fixture.secondCloud.uploadedTombstoneIDs
            XCTAssertEqual(uploaded, [], variant)
            XCTAssertEqual(uploadedTombstones, [], variant)
        }
    }

    func testClearDuringTheSetAsideDropsTheCopyWaitingForIt() async throws {
        let older = clipboardEntry("first generation")
        let copiedText = "copied before Clear History"
        let gate = ClipboardBindingResetGate(holding: .historyCleared)
        let fixture = try await makeHistoryAdoptingANewSyncGeneration(
            syncing: [older], resetStep: { try await gate.reach($0) }
        )
        let history = fixture.history
        let run = Task { await history.syncNow() }
        let held = await gate.stepHeld()
        XCTAssertTrue(held, "The set-aside never cleared the stored history")

        writeText(copiedText, to: fixture.pasteboard)
        history.poll()
        history.clear()
        gate.release()
        await run.value
        history.poll()
        await history.flushPersistence()
        history.stopSync()

        XCTAssertFalse(history.entries.contains { $0.text == copiedText })
        let stored = try await history.sharedStore.load()
        XCTAssertFalse(stored.entries.contains { $0.text == copiedText })

        await history.syncNow()
        let uploaded = await fixture.secondCloud.uploadedEntryIDs
        XCTAssertEqual(uploaded, [])
    }

    func testAccountResetStillDropsACopyMadeDuringIt() async throws {
        let older = clipboardEntry("first generation")
        let copiedText = "copied during the account reset"
        let gate = ClipboardBindingResetGate(holding: .historyCleared)
        let fixture = try await makeHistoryAdoptingANewSyncGeneration(
            syncing: [older], resetStep: { try await gate.reach($0) }
        )
        let history = fixture.history
        let reset = Task { await history.resetCloudAccount() }
        let held = await gate.stepHeld()
        XCTAssertTrue(held, "The account reset never cleared the stored history")

        writeText(copiedText, to: fixture.pasteboard)
        history.poll()
        gate.release()
        await reset.value
        history.poll()
        await history.flushPersistence()

        XCTAssertFalse(history.entries.contains { $0.text == copiedText })
    }

    func testCopyDuringAFailedSetAsideStaysInTheCurrentHistory() async throws {
        for step in [ClipboardBindingResetStep.historyCleared, .bindingRemoved] {
            let older = clipboardEntry("first generation")
            let copiedText = "copied during a failed set-aside"
            let gate = ClipboardBindingResetGate(holding: step, failingOnce: step)
            let fixture = try await makeHistoryAdoptingANewSyncGeneration(
                syncing: [older], resetStep: { try await gate.reach($0) }
            )
            let history = fixture.history
            let run = Task { await history.syncNow() }
            let held = await gate.stepHeld()
            XCTAssertTrue(held, "The set-aside never reached \(step)")

            writeText(copiedText, to: fixture.pasteboard)
            history.poll()
            gate.release()
            await run.value
            history.poll()
            await history.flushPersistence()
            // Drops the sync the copy requested. With the old binding kept, it would set the copy aside.
            history.stopSync()

            let copies = history.entries.filter { $0.text == copiedText }
            XCTAssertEqual(copies.count, 1, "Failing at \(step)")
            let copy = try XCTUnwrap(copies.first, "Failing at \(step)")
            let stored = try await history.sharedStore.load()
            XCTAssertTrue(stored.entries.contains { $0.id == copy.id }, "Failing at \(step)")
            guard step == .bindingRemoved else { continue }

            await history.syncNow()
            let uploaded = await fixture.secondCloud.uploadedEntryIDs
            XCTAssertTrue(uploaded.contains(copy.id))
            XCTAssertFalse(uploaded.contains(older.id))
        }
    }

    func testPauseSurvivesRelaunch() throws {
        let context = try makeContext()
        context.history.setPaused(true)

        let reopened = ClipboardHistory(
            pasteboard: context.pasteboard,
            defaults: context.defaults,
            storeURL: context.storeURL
        )

        XCTAssertTrue(reopened.isPaused)
        writeText("Ignored after relaunch", to: context.pasteboard)
        reopened.poll()
        XCTAssertTrue(reopened.entries.isEmpty)
    }

    func testClipboardEntryRejectsTheOldFlatPayloadShape() throws {
        let legacy = """
        {
          "id": "00000000-0000-0000-0000-000000000123",
          "capturedAt": "2026-08-22T12:00:00Z",
          "representations": [],
          "plainText": "Old"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertThrowsError(try decoder.decode(ClipboardEntry.self, from: Data(legacy.utf8)))
    }

    func testCaptureNowRecordsTheCurrentPasteboard() throws {
        let context = try makeContext()
        writeText("Initial", to: context.pasteboard)
        context.history.poll()
        writeText("App copy", to: context.pasteboard)
        context.history.captureNow(from: context.pasteboard)

        XCTAssertEqual(context.history.entries.map(\.text), ["App copy", "Initial"])
    }

    func testRestoreMovesTheEntryToTheTop() throws {
        let context = try makeContext()
        writeText("Older", to: context.pasteboard)
        context.history.poll()
        writeText("Newer", to: context.pasteboard)
        context.history.poll()
        let older = try XCTUnwrap(context.history.entries.last)

        XCTAssertTrue(context.history.restore(older))
        XCTAssertEqual(context.history.entries.map(\.text), ["Older", "Newer"])
        XCTAssertEqual(context.history.entries.first?.id, older.id)
        XCTAssertEqual(context.pasteboard.string(forType: .string), "Older")
    }

    func testHistoryPersistsTheLatestClipboardSnapshot() async throws {
        let context = try makeContext()
        writeText("First", to: context.pasteboard)
        context.history.poll()
        writeText("Second", to: context.pasteboard)
        context.history.poll()

        await context.history.flushPersistence()

        let state = try await ClipboardHistoryStore(url: context.storeURL).load()
        XCTAssertEqual(state.entries.map(\.text), ["Second", "First"])
    }

    func testInitialHistoryLoadKeepsNewerCapturedEntries() async throws {
        let context = try makeContext(persistedEntries: [clipboardEntry("Persisted")])
        writeText("Copied during launch", to: context.pasteboard)

        context.history.poll()
        await context.history.waitForInitialLoad()

        XCTAssertEqual(
            context.history.entries.map(\.text),
            ["Copied during launch", "Persisted"]
        )
    }



    func testHistoryReportsPersistenceFailure() async throws {
        let context = try makeContext()
        try Data("not a directory".utf8).write(
            to: context.storeURL.deletingLastPathComponent(),
            options: .atomic
        )
        writeText("Keep this in memory", to: context.pasteboard)

        context.history.poll()
        await context.history.flushPersistence()

        XCTAssertEqual(context.history.entries.map(\.text), ["Keep this in memory"])
        XCTAssertNotNil(context.history.persistenceError)
    }

    func testHistoryByteLimitKeepsANewestFirstPrefixAfterSkippingOversizedEntries() {
        let oversized = clipboardEntry("O", byteCount: 9)
        let newest = clipboardEntry("N", byteCount: 6)
        let next = clipboardEntry("M", byteCount: 4)
        let older = clipboardEntry("L", byteCount: 2)

        let result = ClipboardHistoryState.trimmed(
            [oversized, newest, next, older],
            maximumEntryBytes: 8,
            maximumHistoryBytes: 8,
            maximumCount: 4
        )

        XCTAssertEqual(result.map(\.text), ["N"])
    }

    func testPinnedHistorySurvivesTrimmingClearAndRelaunch() async throws {
        let context = try makeContext()
        writeText("Keep pinned", to: context.pasteboard)
        context.history.poll()
        let id = try XCTUnwrap(context.history.entries.first?.id)
        await context.history.togglePinned(id: id)
        let pinnedAt = try XCTUnwrap(context.history.entry(id: id)?.pinnedAt)

        for index in 0..<(ClipboardHistoryState.limit + 5) {
            writeText("Entry \(index)", to: context.pasteboard)
            context.history.poll()
        }
        await context.history.flushPersistence()
        XCTAssertEqual(context.history.entries.count, ClipboardHistoryState.limit + 1)
        XCTAssertEqual(context.history.entries.first?.id, id)

        context.history.clear()
        await context.history.flushPersistence()
        XCTAssertEqual(context.history.entries.map(\.id), [id])

        let reopened = ClipboardHistory(pasteboard: context.pasteboard,
            defaults: context.defaults, storeURL: context.storeURL)
        await reopened.waitForInitialLoad()
        XCTAssertEqual(reopened.entries.map(\.id), [id])
        XCTAssertEqual(reopened.entries.first?.pinnedAt, pinnedAt)
    }

    func testCopyingPinnedHistoryDoesNotChangePinOrder() async throws {
        let context = try makeContext()
        writeText("First pin", to: context.pasteboard)
        context.history.poll()
        let firstID = try XCTUnwrap(context.history.entries.first?.id)
        await context.history.togglePinned(id: firstID)
        writeText("Second pin", to: context.pasteboard)
        context.history.poll()
        let secondID = try XCTUnwrap(context.history.entries.first { !$0.isPinned }?.id)
        await context.history.togglePinned(id: secondID)
        let order = context.history.entries.map(\.id)
        let first = try XCTUnwrap(context.history.entry(id: firstID))

        XCTAssertTrue(context.history.restore(first))
        await context.history.flushPersistence()

        XCTAssertEqual(context.history.entries.map(\.id), order)
        XCTAssertEqual(context.history.entry(id: firstID)?.pinnedAt, first.pinnedAt)
        XCTAssertEqual(context.pasteboard.string(forType: .string), "First pin")
    }

    func testPinnedFileCopyUsesOwnedFileAfterSourceDeletionAndRelaunch() async throws {
        let context = try makeContext()
        let directory = context.storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.txt")
        let contents = Data("Keep these file bytes".utf8)
        try contents.write(to: source)
        writeFileURLs([source], to: context.pasteboard)
        context.history.poll()
        let id = try XCTUnwrap(context.history.entries.first?.id)
        await context.history.togglePinned(id: id)
        XCTAssertTrue(try XCTUnwrap(context.history.entry(id: id)).isPinned)
        try FileManager.default.removeItem(at: source)

        let reopened = ClipboardHistory(pasteboard: context.pasteboard,
            defaults: context.defaults, storeURL: context.storeURL)
        await reopened.waitForInitialLoad()
        let pinned = try XCTUnwrap(reopened.entry(id: id))
        XCTAssertTrue(reopened.restore(pinned))
        let pastedString = try XCTUnwrap(context.pasteboard.string(forType: .fileURL))
        let pastedURL = try XCTUnwrap(URL(string: pastedString))
        XCTAssertNotEqual(pastedURL, source)
        XCTAssertEqual(try Data(contentsOf: pastedURL), contents)
        await reopened.flushPersistence()
    }

    func testMissingOwnedFileCopyRecordsVisibleFailure() async throws {
        let diagnostics = ClipboardDiagnosticProbe()
        let context = try makeContext(diagnostics: diagnostics.recorder)
        let directory = context.storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("private-source.txt")
        try Data("Private file bytes".utf8).write(to: source)
        writeFileURLs([source], to: context.pasteboard)
        context.history.poll()
        let id = try XCTUnwrap(context.history.entries.first?.id)
        await context.history.togglePinned(id: id)
        let entry = try XCTUnwrap(context.history.entry(id: id))
        let ownedURL = try XCTUnwrap(context.history.ownedFileStore.resolvedFileURLs(for: entry).first)
        try FileManager.default.removeItem(at: ownedURL)

        XCTAssertFalse(context.history.restore(entry))

        XCTAssertNotNil(context.history.persistenceError)
        XCTAssertEqual(diagnostics.events.count, 1)
        XCTAssertEqual(diagnostics.events.first?.operation, "clipboard.copy_file")
        XCTAssertEqual(diagnostics.events.first?.errorCode, "clipboard.unreadable")
        XCTAssertFalse(diagnostics.events.first?.line.contains("private-source.txt") ?? true)
    }

    func testMissingFileCannotBecomePinned() async throws {
        let context = try makeContext()
        let missing = context.storeURL.deletingLastPathComponent().appendingPathComponent("missing.txt")
        writeFileURLs([missing], to: context.pasteboard)
        context.history.poll()
        let id = try XCTUnwrap(context.history.entries.first?.id)

        await context.history.togglePinned(id: id)

        XCTAssertFalse(try XCTUnwrap(context.history.entry(id: id)).isPinned)
        XCTAssertNotNil(context.history.persistenceError)
    }

    private func makeContext(
        persistedEntries: [ClipboardEntry] = [],
        diagnostics: AppDiagnosticRecorder = AppDiagnosticRecorder.live,
        capture: (generalPasteboard: Bool, conversion: ClipboardEntryConversion)? = nil
    ) throws -> (
        history: ClipboardHistory,
        pasteboard: NSPasteboard,
        storeURL: URL,
        defaults: UserDefaults
    ) {
        let pasteboard = NSPasteboard(
            name: .init("world.sree.snipsnap.clipboard-tests.\(UUID().uuidString)")
        )
        let suite = "Snip SnapClipboardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Snip SnapClipboardTests-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("clipboard.json")
        if !persistedEntries.isEmpty {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(persistedEntries).write(to: storeURL, options: .atomic)
        }
        addTeardownBlock {
            pasteboard.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let history = capture.map { capture in
            ClipboardHistory(
                pasteboard: pasteboard,
                defaults: defaults,
                storeURL: storeURL,
                diagnostics: diagnostics,
                generalPasteboardName: capture.generalPasteboard ? pasteboard.name : .general,
                convertEntry: capture.conversion
            )
        } ?? ClipboardHistory(
            pasteboard: pasteboard,
            defaults: defaults,
            storeURL: storeURL,
            diagnostics: diagnostics
        )
        return (
            history,
            pasteboard,
            storeURL,
            defaults
        )
    }

    private func clipboardEntry(_ text: String) -> ClipboardEntry {
        ClipboardEntry(
            sourceApplication: "Tests",
            items: [
                ClipboardPayloadItem(
                    representations: [
                        ClipboardRepresentation(
                            type: NSPasteboard.PasteboardType.string.rawValue,
                            data: Data(text.utf8)
                        )
                    ]
                )
            ]
        )
    }

    private func clipboardEntry(_ text: String, byteCount: Int) -> ClipboardEntry {
        let textData = Data(text.utf8)
        return ClipboardEntry(
            sourceApplication: "Tests",
            items: [
                ClipboardPayloadItem(
                    representations: [
                        ClipboardRepresentation(
                            type: NSPasteboard.PasteboardType.string.rawValue,
                            data: textData
                        ),
                        ClipboardRepresentation(
                            type: NSPasteboard.PasteboardType.png.rawValue,
                            data: Data(repeating: 0, count: max(byteCount - textData.count, 0))
                        )
                    ]
                )
            ]
        )
    }

    /// Syncs `older` under a first sync generation, then has the app report a second one.
    private func makeHistoryAdoptingANewSyncGeneration(
        syncing older: [ClipboardEntry],
        diagnostics: AppDiagnosticRecorder = AppDiagnosticRecorder.live,
        resetStep: @escaping @MainActor (ClipboardBindingResetStep) async throws -> Void = { _ in }
    ) async throws -> ClipboardGenerationFixture {
        let firstGeneration = clipboardSyncGeneration()
        let secondGeneration = clipboardSyncGeneration()
        let firstCloud = ClipboardHeldUploadCloud(holdsFirstUpload: false)
        let secondCloud = ClipboardHeldUploadCloud(holdsFirstUpload: false)
        let context = try makeContext(diagnostics: diagnostics)
        let history = context.history
        let historyDirectory = context.storeURL.deletingLastPathComponent()
        let syncRoot = historyDirectory.appendingPathComponent("SyncMode", isDirectory: true)
        let service = ClipboardCloudSyncService(
            store: history.sharedStore, syncRootURL: syncRoot,
            makeTransport: { $0 == firstGeneration ? firstCloud : secondCloud },
            resetStep: resetStep
        )
        let source = ClipboardSyncGenerationSource(firstGeneration)
        history.configureSync(
            containerIdentifier: "iCloud.org.example.snipsnap",
            rootURL: syncRoot,
            mainEnabled: { true },
            generation: { await source.generation() },
            makeCloudService: { _, _, _ in service }
        )
        for entry in older { try await history.sharedStore.insert(entry) }
        history.setSyncEnabled(true)
        // Drops the debounced request, so each syncNow is the test's own run.
        history.stopSync()
        await history.syncNow()
        let firstUpload = await firstCloud.uploadedEntryIDs
        XCTAssertEqual(firstUpload, Set(older.map(\.id)))
        XCTAssertEqual(Set(history.entries.map(\.id)), Set(older.map(\.id)))
        source.current = secondGeneration
        return ClipboardGenerationFixture(
            history: history,
            pasteboard: context.pasteboard,
            historyDirectory: historyDirectory,
            bindingURL: syncRoot.appendingPathComponent("clipboard-account-binding.json"),
            firstGeneration: firstGeneration,
            secondGeneration: secondGeneration,
            secondCloud: secondCloud,
            generationSource: source
        )
    }

    /// The history set aside beside the active one, which must be the only one.
    private func onlySetAsideHistory(in fixture: ClipboardGenerationFixture) async throws -> ClipboardHistoryState {
        let histories = try await setAsideHistories(in: fixture)
        XCTAssertEqual(histories.count, 1)
        return try XCTUnwrap(histories.first)
    }

    /// Every history set aside beside the active one. Each set-aside keeps its own file.
    private func setAsideHistories(in fixture: ClipboardGenerationFixture) async throws -> [ClipboardHistoryState] {
        let files = try FileManager.default
            .contentsOfDirectory(at: fixture.historyDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("clipboard-quarantine-") }
        var histories: [ClipboardHistoryState] = []
        for file in files { histories.append(try await ClipboardHistoryStore(url: file).load()) }
        return histories
    }

    /// Copies `text` and returns the entry the history captured from it.
    private func capture(_ text: String, in fixture: ClipboardGenerationFixture) async throws -> ClipboardEntry {
        writeText(text, to: fixture.pasteboard)
        fixture.history.poll()
        await fixture.history.waitForPendingCapture()
        await fixture.history.flushPersistence()
        return try XCTUnwrap(fixture.history.entries.first { $0.text == text })
    }

    private func makeSyncedHistory(_ gate: ClipboardSyncGenerationGate) throws -> ClipboardHistory {
        let context = try makeContext()
        context.history.configureSync(
            containerIdentifier: "iCloud.org.example.snipsnap",
            rootURL: context.storeURL.deletingLastPathComponent()
                .appendingPathComponent("SyncMode", isDirectory: true),
            mainEnabled: { true },
            generation: { try await gate.generation() }
        )
        return context.history
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        reportingTimeout: Bool = true,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if reportingTimeout { XCTAssertTrue(condition()) }
    }

    private func writeText(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(text, forType: .string))
    }

    private func writeFileURLs(_ urls: [URL], to pasteboard: NSPasteboard) {
        let items = urls.map { url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(items))
    }
}

final class SnipPinTests: StoreBackedTestCase {
    @MainActor
    func testPinningDoneSnipMakesItUndoneAndPersistsAcrossRelaunch() async throws {
        let url = try storeURL()
        let repository = try JSONSnipLibrary(fileURL: url)
        let added = try await repository.add(content: "Reusable", origin: .quickEntry)
        let snip = try XCTUnwrap(added)
        let model = AppModel(library: repository)
        await model.reload()
        await model.toggleDoneNow(id: snip.id)
        XCTAssertTrue(try XCTUnwrap(model.snips.first).isDone)

        await model.togglePinned(id: snip.id)

        let pinned = try XCTUnwrap(model.snips.first)
        XCTAssertTrue(pinned.isPinned)
        XCTAssertFalse(pinned.isDone)
        await model.toggleDoneNow(id: snip.id)
        XCTAssertFalse(try XCTUnwrap(model.snips.first).isDone)

        let reopened = AppModel(library: try JSONSnipLibrary(fileURL: url))
        await reopened.reload()
        XCTAssertEqual(reopened.snips.first?.pinnedAt, pinned.pinnedAt)
        XCTAssertFalse(try XCTUnwrap(reopened.snips.first).isDone)
        await reopened.togglePinned(id: snip.id)
        XCTAssertFalse(try XCTUnwrap(reopened.snips.first).isPinned)
        XCTAssertFalse(try XCTUnwrap(reopened.snips.first).isDone)
    }

    @MainActor
    func testBulkPinPreservesSelectionAndMakesDoneSnipsUndone() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let firstResult = try await repository.add(content: "First", origin: .quickEntry)
        let secondResult = try await repository.add(content: "Second", origin: .quickEntry)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)
        let model = AppModel(library: repository)
        await model.reload()
        model.selection = [first.id, second.id]
        await model.toggleDoneNow(id: first.id)

        await model.setPinned(ids: model.selection, pinned: true)

        XCTAssertEqual(model.selection, [first.id, second.id])
        XCTAssertEqual(model.snips.count, 2)
        XCTAssertTrue(model.snips.allSatisfy { $0.isPinned && !$0.isDone })
    }
}
