import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest

final class ClipboardHistoryTests: XCTestCase {
    func testRemovedFilesArePrunedButQuarantineKeepsItsBytes() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ClipboardFileStore(rootURL: directory.appendingPathComponent("ClipboardFiles"))
        let store = ClipboardHistoryStore(url: directory.appendingPathComponent("clipboard.json"))
        let file = ClipboardOwnedFile(id: UUID(), name: "sample.txt", relativePath: "sample.txt")
        try files.importOwnedFile(file, data: Data("sample".utf8))
        var clip = text("file"); clip.ownedFiles = [file]
        try await store.insert(clip)
        try await store.clearUnpinned()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try files.url(for: file).path))
        try files.importOwnedFile(file, data: Data("sample".utf8))
        clip = text("quarantined"); clip.ownedFiles = [file]
        try await store.insert(clip)
        let state = try await store.load()
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("clipboard-quarantine-test.json"))
        try await store.delete(id: clip.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try files.url(for: file).path))
    }

    func testOfflinePinsSurviveAutomaticTrimAndClearButNotExplicitDelete() {
        let old = text("old", time: 1)
        var offline = ClipboardHistoryState(entries: [old])
        offline.setPinned(true, id: old.id)
        var active = ClipboardHistoryState(entries: [old] + (0..<110).map { text("new-\($0)", time: Double($0 + 2)) })
        active.clearUnpinned()
        active.merge(offline)
        XCTAssertEqual(active.entries.map(\.id), [old.id])
        active.delete(id: old.id)
        active.merge(offline)
        XCTAssertTrue(active.entries.isEmpty)
    }

    func testConcurrentPinTogglesUseOneStoreTransactionEach() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardHistoryStore(url: directory.appendingPathComponent("clipboard.json"))
        let clip = text("toggle")
        try await store.insert(clip)
        async let first = store.togglePinned(id: clip.id)
        async let second = store.togglePinned(id: clip.id)
        _ = try await (first, second)
        let result = try await store.load()
        XCTAssertFalse(result.entries[0].isPinned)
    }

    private func text(_ value: String, id: UUID = UUID(), time: Double = 10, pinned: Double? = nil) -> ClipboardEntry {
        ClipboardEntry(id: id, capturedAt: Date(timeIntervalSince1970: time), items: [
            ClipboardPayloadItem(representations: [ClipboardRepresentation(type: "public.utf8-plain-text", data: Data(value.utf8))])
        ], pinnedAt: pinned.map { Date(timeIntervalSince1970: $0) })
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func testPinsSurviveLimitAndClearAndCopyKeepsPinOrder() {
        let pinned = text("keep", time: 1, pinned: 2)
        var state = ClipboardHistoryState(entries: [pinned] + (0..<130).map { text("\($0)", time: Double($0 + 10)) })
        XCTAssertEqual(state.entries.count, 101)
        XCTAssertEqual(state.entries.first?.id, pinned.id)
        state.insert(text("keep", time: 500))
        XCTAssertEqual(state.entries.first?.pinnedAt, pinned.pinnedAt)
        XCTAssertEqual(state.entries.first?.id, pinned.id)
        state.clearUnpinned(at: Date(timeIntervalSince1970: 600))
        XCTAssertEqual(state.entries.map(\.id), [pinned.id])
        XCTAssertEqual(state.retentionTombstones.count, 130)
        state.delete(id: pinned.id)
        XCTAssertTrue(state.entries.isEmpty)
    }
    func testMergeConvergesAndDeletingDuplicateDoesNotResurrect() {
        let first = text("same", id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, time: 1)
        let second = text("same", id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, time: 2, pinned: 2)
        var a = ClipboardHistoryState(entries: [first]); var b = ClipboardHistoryState(entries: [second])
        a.merge(b); b.merge(ClipboardHistoryState(entries: [first]))
        XCTAssertEqual(a, b); XCTAssertEqual(a.entries.count, 1)
        XCTAssertEqual(a.entries.first?.id, first.id); XCTAssertTrue(a.entries.first!.isPinned)
        a.delete(id: first.id, at: Date(timeIntervalSince1970: 5))
        a.merge(ClipboardHistoryState(entries: [second]))
        XCTAssertTrue(a.entries.isEmpty)
        a.insert(text("same", time: 10))
        XCTAssertEqual(a.entries.count, 1)
    }
    func testUnpinSurvivesReplayedDuplicateAndTrimStaysDeleted() {
        let first = text("same", time: 1, pinned: 1)
        let duplicate = text("same", time: 2, pinned: 2)
        var state = ClipboardHistoryState(entries: [first, duplicate])
        let canonical = state.entries[0].id
        state.setPinned(false, id: canonical, at: Date(timeIntervalSince1970: 100))
        state.merge(ClipboardHistoryState(entries: [first, duplicate]))
        XCTAssertFalse(state.entries[0].isPinned)
        let oldest = text("expired", time: 0)
        var trimmed = ClipboardHistoryState(entries: [oldest] + (0..<100).map { text("\($0)", time: Double($0 + 1)) })
        XCTAssertNotNil(trimmed.retentionTombstones[oldest.id])
        trimmed.clearUnpinned()
        trimmed.merge(ClipboardHistoryState(entries: [oldest]))
        XCTAssertTrue(trimmed.entries.isEmpty)
    }
    func testDeletionWinsOfflinePinAndRepeatedMerge() {
        let entry = text("old")
        var deleted = ClipboardHistoryState(entries: [entry]); deleted.delete(id: entry.id)
        var offline = ClipboardHistoryState(entries: [entry]); offline.setPinned(true, id: entry.id, at: .distantFuture)
        deleted.merge(offline); deleted.merge(offline)
        XCTAssertTrue(deleted.entries.isEmpty)
    }
    func testPinByteExemptionAndUnpinnedBounds() {
        let pin = text(String(repeating: "a", count: 100), pinned: 5)
        let state = ClipboardHistoryState.trimmed([text("12345", time: 4), text("123456", time: 3), pin], maximumEntryBytes: 5, maximumHistoryBytes: 5, maximumCount: 1)
        XCTAssertEqual(state.count, 2); XCTAssertEqual(state.last?.id, pin.id)
    }
    func testFingerprintCacheUpdatesOnPayloadMutationAndSurvivesRoundTrip() throws {
        var entry = text("before")
        let before = entry.fingerprint
        entry.items[0].representations[0] = ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("after".utf8))
        XCTAssertNotEqual(entry.fingerprint, before)
        XCTAssertEqual(entry.fingerprint, text("after").fingerprint)
        let decoded = try JSONDecoder().decode(ClipboardEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.fingerprint, entry.fingerprint)
        entry.payloadFingerprint = before
        entry.items = text("sanitized").items
        XCTAssertEqual(entry.fingerprint, before)
        let shared = try JSONDecoder().decode(ClipboardEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(shared.fingerprint, before)
        entry.payloadFingerprint = nil
        XCTAssertEqual(entry.fingerprint, text("sanitized").fingerprint)
    }
    func testImageRepresentationsRecognizeSharedImageTypesAndPreferPNGThenTIFF() {
        for type in ["public.jpeg", "public.heic", "com.compuserve.gif", "org.webmproject.webp"] {
            let representation = ClipboardRepresentation(type: type, data: Data([1]))
            let entry = ClipboardEntry(items: [ClipboardPayloadItem(representations: [representation])])
            XCTAssertEqual(entry.imageRepresentations, [representation], type)
            XCTAssertEqual(entry.standaloneImageRepresentations, [representation], type)
        }
        let representations = ["public.heic", "public.jpeg", "public.tiff", "public.png"].map { ClipboardRepresentation(type: $0, data: Data([1])) }
        let entry = ClipboardEntry(items: [ClipboardPayloadItem(representations: representations)])
        XCTAssertEqual(entry.imageRepresentations.first?.type, "public.png")
        let withoutPNG = ClipboardEntry(items: [ClipboardPayloadItem(representations: Array(representations.dropLast()))])
        XCTAssertEqual(withoutPNG.imageRepresentations.first?.type, "public.tiff")
    }
    func testTrimKeepsInputPrefixSkipsOversizedAndStillKeepsLaterPins() {
        let oversized = text("123456789", time: 1)
        let newest = text("123456", time: 2)
        let next = text("1234", time: 3)
        let older = text("12", time: 4)
        let pin = text("pinned", time: 5, pinned: 5)
        let result = ClipboardHistoryState.trimmed([oversized, newest, next, older, pin], maximumEntryBytes: 8, maximumHistoryBytes: 8, maximumCount: 4)
        XCTAssertEqual(result.map(\.id), [newest.id, pin.id])
    }
    func testLegacyJSONMigrationPreservesIdentityAndRichText() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let legacy = """
        [{"id":"\(id.uuidString)","capturedAt":"2026-01-01T00:00:00Z","sourceApplication":"Editor","items":[{"representations":[{"type":"public.rtf","data":"YWJj"}]}],"plainText":"formatted text"}]
        """
        let url = directory.appendingPathComponent("clipboard.json")
        try Data(legacy.utf8).write(to: url)
        let store = ClipboardHistoryStore(url: url)
        let state = try await store.load()
        XCTAssertEqual(state.entries.first?.id, id); XCTAssertEqual(state.entries.first?.text, "formatted text")
        XCTAssertFalse(state.entries.first!.isPinned)
        try await store.save(state)
        let loaded = try await store.load(); XCTAssertEqual(loaded, state)
    }
    func testPersistencePreservesRapidPinUnpinAndSharedFileEligibility() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardHistoryStore(url: directory.appendingPathComponent("clipboard.json"))
        let entry = text("rapid")
        try await store.insert(entry)
        let pinned = try await store.setPinned(true, id: entry.id, at: Date(timeIntervalSince1970: 100.1))
        let unpinned = try await store.setPinned(false, id: entry.id, at: Date(timeIntervalSince1970: 100.2))
        XCTAssertGreaterThan(unpinned.entries[0].modifiedAt, pinned.entries[0].modifiedAt)
        let merged = try await store.merge(pinned)
        XCTAssertFalse(merged.entries[0].isPinned)
        var file = ClipboardEntry(items: [ClipboardPayloadItem(representations: [ClipboardRepresentation(type: "public.file-url", data: Data("file:///original.txt".utf8))])],
            ownedFiles: [ClipboardOwnedFile(name: "original.txt", relativePath: "original.txt")])
        XCTAssertFalse(file.isSyncEligible)
        file.hasBeenShared = true
        XCTAssertTrue(file.isSyncEligible)
    }
    func testPinCopiesFilesAndMissingSourceLeavesHistoryUnpinned() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.txt"); try Data("keep".utf8).write(to: source)
        let entry = ClipboardEntry(items: [ClipboardPayloadItem(representations: [ClipboardRepresentation(type: "public.file-url", data: Data(source.absoluteString.utf8))])])
        let files = ClipboardFileStore(rootURL: directory.appendingPathComponent("files"))
        let store = ClipboardHistoryStore(url: directory.appendingPathComponent("clipboard.json"), fileStore: files)
        try await store.insert(entry)
        let pinned = try await store.setPinned(true, id: entry.id).entries[0]
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: files.resolvedFileURLs(for: pinned)[0]), Data("keep".utf8))
        XCTAssertTrue(pinned.isSyncEligible)
        var missing = entry; missing.items[0].representations = [ClipboardRepresentation(type: "public.file-url", data: Data(directory.appendingPathComponent("missing.txt").absoluteString.utf8))]
        missing = ClipboardEntry(items: missing.items)
        try await store.insert(missing)
        do { _ = try await store.setPinned(true, id: missing.id); XCTFail("Pin should fail") } catch { }
        let loaded = try await store.load()
        XCTAssertFalse(loaded.entries.first { $0.id == missing.id }!.isPinned)
    }
    func testOversizeSparseFileRejectsPinBeforeCopy() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("large.dat")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(ClipboardHistoryState.entryByteLimit + 1)); try handle.close()
        let entry = ClipboardEntry(items: [ClipboardPayloadItem(representations: [ClipboardRepresentation(type: "public.file-url", data: Data(source.absoluteString.utf8))])])
        let files = ClipboardFileStore(rootURL: directory.appendingPathComponent("files"))
        XCTAssertThrowsError(try files.preserveFiles(of: entry))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.rootURL.path))
    }
    func testDeleteLosingAliasPropagatesToCanonical() {
        let first = text("same"); let duplicate = text("same")
        var merged = ClipboardHistoryState(entries: [first, duplicate])
        let canonical = merged.entries[0].id
        let losing = first.id == canonical ? duplicate : first
        var offline = ClipboardHistoryState(entries: [losing]); offline.delete(id: losing.id)
        merged.merge(offline)
        XCTAssertNotNil(merged.tombstones[canonical])
        merged.merge(ClipboardHistoryState(entries: [first, duplicate]))
        XCTAssertTrue(merged.entries.isEmpty)
    }
    func testPartialFilePreservationLeavesNoCopiesAndRejectsTraversal() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ok.txt"); try Data("x".utf8).write(to: source)
        let files = ClipboardFileStore(rootURL: directory.appendingPathComponent("files"))
        let entry = ClipboardEntry(items: [source, directory.appendingPathComponent("missing")].map { ClipboardPayloadItem(representations: [ClipboardRepresentation(type: "public.file-url", data: Data($0.absoluteString.utf8))]) })
        XCTAssertThrowsError(try files.preserveFiles(of: entry))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.rootURL.path))
        XCTAssertThrowsError(try files.importOwnedFile(ClipboardOwnedFile(name: "escape", relativePath: "../escape"), data: Data()))
    }
}
