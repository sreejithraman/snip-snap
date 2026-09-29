import CoreGraphics
import ImageIO
@preconcurrency import QuickLookThumbnailing
import SnipSnapCore
import SwiftUI

struct AttachmentDraft: Equatable, Identifiable {
    enum Source: Equatable {
        case existing(attachmentID: UUID)
        case added
        case replacement(attachmentID: UUID)

        var originalAttachmentID: UUID? {
            switch self {
            case .existing(let attachmentID), .replacement(let attachmentID): attachmentID
            case .added: nil
            }
        }

        var isStaged: Bool {
            switch self {
            case .existing: false
            case .added, .replacement: true
            }
        }
    }

    let id: UUID
    let fileName: String
    let byteCount: Int64
    let url: URL?
    let source: Source
    var contentType: String? = nil

    static func added(_ file: StagedAttachment) -> AttachmentDraft {
        AttachmentDraft(
            id: UUID(),
            fileName: file.fileName,
            byteCount: file.byteCount,
            url: file.url,
            source: .added
        )
    }

    var libraryEdit: SnipAttachmentEdit? {
        switch source {
        case .existing(let attachmentID):
            .existing(attachmentID: attachmentID)
        case .added:
            url.map(SnipAttachmentEdit.added)
        case .replacement(let attachmentID):
            url.map { .replacement(attachmentID: attachmentID, sourceURL: $0) }
        }
    }

    @MainActor
    func previewURL(
        prepareExisting: (UUID) async -> URL?
    ) async -> URL? {
        switch source {
        case .existing(let attachmentID):
            await prepareExisting(attachmentID)
        case .added, .replacement:
            url
        }
    }

}

struct AttachmentEditorSection: View {
    let attachments: [AttachmentDraft]
    let model: IOSAppModel
    let isStaging: Bool
    let isDisabled: Bool
    let preview: (AttachmentDraft) -> Void
    let replace: (AttachmentDraft, AttachmentSource) -> Void
    let remove: (AttachmentDraft) -> Void
    let add: (AttachmentSource) -> Void

    var body: some View {
        Section("Attachments") {
            if !attachments.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 132), spacing: 12)],
                    spacing: 16
                ) {
                    ForEach(attachments) { attachment in
                        AttachmentEditorTile(
                            attachment: attachment,
                            model: model,
                            isDisabled: isDisabled,
                            preview: { preview(attachment) },
                            replace: { replace(attachment, $0) },
                            remove: { remove(attachment) }
                        )
                    }
                }
                .padding(.vertical, 8)
            }

            AttachmentSourceMenu(choose: add) {
                Label("Add attachments", systemImage: "paperclip")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .disabled(isDisabled)
            .accessibilityIdentifier("add-attachments")

            if isStaging {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Adding files…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("copying-attachments")
            }
        }
    }
}

private struct AttachmentEditorTile: View {
    let attachment: AttachmentDraft
    let model: IOSAppModel
    let isDisabled: Bool
    let preview: () -> Void
    let replace: (AttachmentSource) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let url = displayURL {
                AttachmentPreviewTile(
                    item: AttachmentPreviewItem(
                        id: attachment.id,
                        fileName: attachment.fileName,
                        byteCount: attachment.byteCount,
                        url: url
                    ),
                    action: preview
                )
                .disabled(isDisabled)
                .accessibilityIdentifier("attachment-row-\(attachment.fileName)")
            } else {
                Button(action: preview) {
                    ContentUnavailableView(
                        attachment.fileName,
                        systemImage: "icloud.and.arrow.down",
                        description: Text("Download and preview")
                    )
                    .aspectRatio(1, contentMode: .fit)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .accessibilityIdentifier("download-attachment-\(attachment.fileName)")
            }

            HStack(spacing: 8) {
                AttachmentSourceMenu(choose: replace) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(isDisabled)
                .accessibilityLabel("Replace \(attachment.fileName)")
                .accessibilityIdentifier("replace-attachment-\(attachment.fileName)")
                Spacer()
                Button("Remove", systemImage: "trash", role: .destructive, action: remove)
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .disabled(isDisabled)
                    .accessibilityLabel("Remove \(attachment.fileName)")
                    .accessibilityIdentifier("remove-attachment-\(attachment.fileName)")
            }
            .buttonStyle(.borderless)
        }
        .modifier(VisibleAttachmentPreparation(
            attachmentID: attachment.id,
            fileName: attachment.fileName,
            contentType: attachment.contentType,
            model: model,
            enabled: !attachment.source.isStaged
        ))
    }

    private var displayURL: URL? {
        if case .existing = attachment.source {
            return model.usableAttachmentURL(for: attachment.id)
        }
        return attachment.url
    }
}

struct VisibleAttachmentPreparation: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var preparationID = UUID()
    let attachmentID: UUID
    let fileName: String
    let contentType: String?
    let model: IOSAppModel
    var enabled = true

    func body(content: Content) -> some View {
        content
            .task(id: preparationID) {
                guard enabled,
                      AttachmentImageType.shouldPrepare(
                        fileName: fileName, contentType: contentType
                      ),
                      model.usableAttachmentURL(for: attachmentID) == nil,
                      model.attachmentTransferState(for: attachmentID) == .available else { return }
                _ = await model.prepareAttachment(
                    attachmentID, for: .preview, showsFailureAlert: false
                )
            }
            .onChange(of: model.attachmentTransferState(for: attachmentID)) { _, state in
                if state == .available { preparationID = UUID() }
            }
            .onChange(of: model.usableAttachmentURL(for: attachmentID)) { oldURL, newURL in
                if oldURL != nil && newURL == nil { preparationID = UUID() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { preparationID = UUID() }
            }
    }
}

struct StagedAttachment: Sendable {
    let fileName: String
    let byteCount: Int64
    let url: URL
}

enum AttachmentDraftLifecycle {
    static func allowsDismissal(isSaving: Bool, isStaging: Bool) -> Bool {
        !isSaving && !isStaging
    }

    static func allowsSaving(
        isSaving: Bool,
        isStaging: Bool,
        isImporting: Bool,
        isPickingMedia: Bool,
        isPreviewing: Bool
    ) -> Bool {
        !isSaving && !isStaging && !isImporting && !isPickingMedia && !isPreviewing
    }

}

enum AttachmentDraftStager {
    static func stage(_ urls: [URL], in root: URL) async throws -> [StagedAttachment] {
        let worker = Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let batchDirectory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            var staged: [StagedAttachment] = []
            do {
                for sourceURL in urls {
                    try Task.checkCancellation()
                    let didAccess = sourceURL.startAccessingSecurityScopedResource()
                    defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
                    let sourceValues = try sourceURL.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                    )
                    guard sourceValues.isRegularFile == true,
                        sourceValues.isSymbolicLink != true
                    else { throw SnipLibraryError.attachmentCopyFailed }

                    let fileName = sourceURL.lastPathComponent.isEmpty
                        ? "Attachment" : sourceURL.lastPathComponent
                    let directory = batchDirectory.appendingPathComponent(
                        UUID().uuidString,
                        isDirectory: true
                    )
                    let destination = directory.appendingPathComponent(fileName, isDirectory: false)
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                    try Task.checkCancellation()
                    try fileManager.copyItem(at: sourceURL, to: destination)
                    let values = try destination.resourceValues(
                        forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
                    )
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw SnipLibraryError.attachmentCopyFailed
                    }
                    staged.append(
                        StagedAttachment(
                            fileName: fileName,
                            byteCount: Int64(values.fileSize ?? 0),
                            url: destination
                        )
                    )
                }
                return staged
            } catch {
                clean(batchDirectory)
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated static func clean(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    nonisolated static func clean(_ staged: [StagedAttachment]) {
        let batchDirectories = Set(staged.map {
            $0.url.deletingLastPathComponent().deletingLastPathComponent()
        })
        for directory in batchDirectories {
            clean(directory)
        }
    }
}

struct AttachmentPreviewItem: Identifiable {
    let id: UUID
    let fileName: String
    let byteCount: Int64
    let url: URL
}

struct AttachmentPreviewTile: View {
    let item: AttachmentPreviewItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                AttachmentThumbnail(url: item.url)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Text(item.fileName)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .aspectRatio(1, contentMode: .fit)
        .buttonStyle(.plain)
        .accessibilityLabel("Preview \(item.fileName)")
        .accessibilityIdentifier("attachment-preview-\(item.fileName)")
    }
}

struct AttachmentThumbnail: View {
    let url: URL
    var fillsTile = false
    @Environment(\.displayScale) private var displayScale
    @State private var image: Image?
    @State private var loadedURL: URL?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle()
                    .fill(.quaternary)
                if let displayedImage {
                    let inset: CGFloat = fillsTile ? 0 : 8
                    displayedImage
                        .resizable()
                        .aspectRatio(contentMode: fillsTile ? .fill : .fit)
                        .frame(
                            width: max(0, geometry.size.width - inset * 2),
                            height: max(0, geometry.size.height - inset * 2)
                        )
                        .clipped()
                } else {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .task(id: url) {
            await loadThumbnail()
        }
    }

    private var displayedImage: Image? {
        if loadedURL == url, let image { return image }
        guard let cached = AttachmentThumbnailCache.shared.cachedImage(
            for: url,
            size: AttachmentThumbnailCache.tileSize,
            scale: displayScale
        ) else { return nil }
        return Image(decorative: cached, scale: displayScale, orientation: .up)
    }

    private func loadThumbnail() async {
        let requestedURL = url
        guard
            let thumbnail = await AttachmentThumbnailCache.shared.image(
                for: requestedURL,
                size: AttachmentThumbnailCache.tileSize,
                scale: displayScale
            ),
            !Task.isCancelled
        else { return }
        loadedURL = requestedURL
        image = Image(decorative: thumbnail, scale: displayScale, orientation: .up)
    }
}

@MainActor
final class AttachmentThumbnailCache {
    static let tileSize = CGSize(width: 256, height: 256)
    static let shared = AttachmentThumbnailCache()

    private final class StoredImage: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private struct InFlight {
        let task: Task<CGImage?, Never>
        var waiters: Set<UUID>
    }

    private let images = NSCache<NSString, StoredImage>()
    private let resolvedKeys = NSCache<NSString, NSString>()
    private var inFlight: [String: InFlight] = [:]
    private let decode: @Sendable (URL, CGSize, CGFloat) async -> CGImage?

    init(decode: @escaping @Sendable (URL, CGSize, CGFloat) async -> CGImage? = decodeThumbnail) {
        images.countLimit = 180
        images.totalCostLimit = 96 * 1_024 * 1_024
        resolvedKeys.countLimit = 360
        self.decode = decode
    }

    func cachedImage(for url: URL, size: CGSize, scale: CGFloat) -> CGImage? {
        let lookup = Self.lookupKey(url: url, size: size, scale: scale)
        guard let key = resolvedKeys.object(forKey: lookup as NSString) else { return nil }
        return images.object(forKey: key)?.image
    }

    func image(for url: URL, size: CGSize, scale: CGFloat) async -> CGImage? {
        let lookup = Self.lookupKey(url: url, size: size, scale: scale)
        let key = await Task.detached(priority: .utility) {
            Self.versionedKey(url: url, size: size, scale: scale)
        }.value
        resolvedKeys.setObject(key as NSString, forKey: lookup as NSString)
        if let image = images.object(forKey: key as NSString)?.image { return image }

        let waiterID = UUID()
        let task: Task<CGImage?, Never>
        if var request = inFlight[key] {
            request.waiters.insert(waiterID)
            inFlight[key] = request
            task = request.task
        } else {
            let decode = decode
            task = Task.detached(priority: .userInitiated) {
                await decode(url, size, scale)
            }
            inFlight[key] = InFlight(task: task, waiters: [waiterID])
        }

        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.releaseWaiter(waiterID, for: key)
            }
        }
        releaseWaiter(waiterID, for: key)
        guard !Task.isCancelled, let image else { return nil }
        images.setObject(
            StoredImage(image),
            forKey: key as NSString,
            cost: image.bytesPerRow * image.height
        )
        return image
    }

    private func releaseWaiter(_ waiterID: UUID, for key: String) {
        guard var request = inFlight[key], request.waiters.remove(waiterID) != nil else { return }
        if request.waiters.isEmpty {
            request.task.cancel()
            inFlight[key] = nil
        } else {
            inFlight[key] = request
        }
    }

    private nonisolated static func lookupKey(url: URL, size: CGSize, scale: CGFloat) -> String {
        "\(url.standardizedFileURL.path)|\(pixelLength(size, scale: scale))"
    }

    private nonisolated static func versionedKey(url: URL, size: CGSize, scale: CGFloat) -> String {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [
            .fileResourceIdentifierKey,
            .contentModificationDateKey,
            .fileSizeKey,
        ])
        let identity = values?.fileResourceIdentifier.map(String.init(describing:))
            ?? url.standardizedFileURL.path
        let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let bytes = values?.fileSize ?? -1
        return "\(lookupKey(url: url, size: size, scale: scale))|\(identity)|\(modified)|\(bytes)"
    }

    private nonisolated static func pixelLength(_ size: CGSize, scale: CGFloat) -> Int {
        max(1, Int(ceil(max(size.width, size.height) * scale)))
    }

    private nonisolated static func decodeThumbnail(
        url: URL,
        size: CGSize,
        scale: CGFloat
    ) async -> CGImage? {
        if !Task.isCancelled,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let thumbnail = makeImageThumbnail(source: source, size: size, scale: scale) {
            return thumbnail
        }
        guard !Task.isCancelled else { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: [.thumbnail, .lowQualityThumbnail, .icon]
        )
        do {
            let representation = try await withTaskCancellationHandler {
                try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            } onCancel: {
                QLThumbnailGenerator.shared.cancel(request)
            }
            return representation.cgImage
        } catch {
            return nil
        }
    }

    private nonisolated static func makeImageThumbnail(
        source: CGImageSource,
        size: CGSize,
        scale: CGFloat
    ) -> CGImage? {
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelLength(size, scale: scale),
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
