import CoreGraphics
import ImageIO
@preconcurrency import QuickLookThumbnailing
import SnipSnapCore
import SwiftUI
import UniformTypeIdentifiers

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

    func applyingPreparedURL(
        _ preparedURL: URL,
        requestedDraft: AttachmentDraft
    ) -> AttachmentDraft? {
        guard self == requestedDraft else { return nil }
        return AttachmentDraft(
            id: id,
            fileName: fileName,
            byteCount: byteCount,
            url: preparedURL,
            source: source
        )
    }
}

struct AttachmentEditorSection: View {
    let attachments: [AttachmentDraft]
    let isStaging: Bool
    let isDisabled: Bool
    let preview: (AttachmentDraft) -> Void
    let replace: (AttachmentDraft) -> Void
    let remove: (AttachmentDraft) -> Void
    let add: () -> Void

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
                            isDisabled: isDisabled,
                            preview: { preview(attachment) },
                            replace: { replace(attachment) },
                            remove: { remove(attachment) }
                        )
                    }
                }
                .padding(.vertical, 8)
            }

            Button("Add Files", systemImage: "paperclip", action: add)
                .disabled(isDisabled)
                .accessibilityIdentifier("add-attachments")

            if isStaging {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Copying files…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("copying-attachments")
            }
        }
    }
}

private struct AttachmentEditorTile: View {
    let attachment: AttachmentDraft
    let isDisabled: Bool
    let preview: () -> Void
    let replace: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let url = attachment.url {
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
                        description: Text("Download to Preview")
                    )
                    .aspectRatio(1, contentMode: .fit)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .accessibilityIdentifier("download-attachment-\(attachment.fileName)")
            }

            HStack(spacing: 8) {
                Button("Replace", systemImage: "arrow.triangle.2.circlepath", action: replace)
                    .labelStyle(.iconOnly)
                    .disabled(isDisabled)
                    .accessibilityLabel("Replace \(attachment.fileName)")
                    .accessibilityIdentifier("replace-attachment-\(attachment.fileName)")
                Spacer()
                Button("Remove", systemImage: "trash", role: .destructive, action: remove)
                    .labelStyle(.iconOnly)
                    .disabled(isDisabled)
                    .accessibilityLabel("Remove \(attachment.fileName)")
                    .accessibilityIdentifier("remove-attachment-\(attachment.fileName)")
            }
            .buttonStyle(.borderless)
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
        isPreviewing: Bool
    ) -> Bool {
        !isSaving && !isStaging && !isImporting && !isPreviewing
    }

    static func shouldClean(
        isSaving: Bool,
        isStaging: Bool,
        isImporting: Bool,
        isPreviewing: Bool
    ) -> Bool {
        !isSaving && !isStaging && !isImporting && !isPreviewing
    }
}

enum AttachmentDraftStager {
    static func stage(_ urls: [URL], in root: URL) async throws -> [StagedAttachment] {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let batchDirectory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            var staged: [StagedAttachment] = []
            do {
                for sourceURL in urls {
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
        }.value
    }

    nonisolated static func clean(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
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
    @Environment(\.displayScale) private var displayScale
    @State private var image: Image?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)
            if let image {
                image
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            image = nil
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        guard
            let thumbnail = await AttachmentThumbnailCache.shared.thumbnail(
                for: url,
                size: CGSize(width: 256, height: 256),
                scale: displayScale
            ),
            !Task.isCancelled
        else { return }
        image = Image(decorative: thumbnail, scale: displayScale, orientation: .up)
    }
}

private actor AttachmentThumbnailCache {
    static let shared = AttachmentThumbnailCache()

    private struct Key: Hashable {
        let fileIdentity: String
        let changeDate: Date?
        let byteCount: Int?
        let pixelWidth: Int
        let pixelHeight: Int
        let scale: Int
    }

    private let limit = 96
    private var images: [Key: CGImage] = [:]
    private var recentKeys: [Key] = []

    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> CGImage? {
        let values = try? url.resourceValues(
            forKeys: [
                .fileResourceIdentifierKey,
                .contentModificationDateKey,
                .fileSizeKey,
                .contentTypeKey,
            ]
        )
        let key = Key(
            fileIdentity: values?.fileResourceIdentifier.map(String.init(describing:))
                ?? url.standardizedFileURL.path,
            changeDate: values?.contentModificationDate,
            byteCount: values?.fileSize,
            pixelWidth: Int(size.width * scale),
            pixelHeight: Int(size.height * scale),
            scale: Int(scale * 100)
        )
        if let cached = images[key] {
            markRecent(key)
            return cached
        }

        if values?.contentType?.conforms(to: .image) == true,
            !Task.isCancelled,
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let thumbnail = Self.makeImageThumbnail(source: source, size: size, scale: scale)
        {
            store(thumbnail, for: key)
            return thumbnail
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: [.thumbnail, .lowQualityThumbnail, .icon]
        )
        let representation: QLThumbnailRepresentation
        do {
            representation = try await withTaskCancellationHandler {
                try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            } onCancel: {
                QLThumbnailGenerator.shared.cancel(request)
            }
        } catch {
            return nil
        }
        guard !Task.isCancelled else { return nil }
        store(representation.cgImage, for: key)
        return representation.cgImage
    }

    private nonisolated static func makeImageThumbnail(
        source: CGImageSource,
        size: CGSize,
        scale: CGFloat
    ) -> CGImage? {
        let maxPixelSize = max(1, Int(ceil(max(size.width, size.height) * scale)))
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    private func store(_ image: CGImage, for key: Key) {
        images[key] = image
        markRecent(key)
        while recentKeys.count > limit {
            images.removeValue(forKey: recentKeys.removeFirst())
        }
    }

    private func markRecent(_ key: Key) {
        recentKeys.removeAll { $0 == key }
        recentKeys.append(key)
    }
}
