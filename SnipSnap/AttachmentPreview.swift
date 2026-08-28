import AppKit
import SwiftUI

enum AttachmentPreviewMetrics {
    static let side: CGFloat = 64
    static let cornerRadius: CGFloat = 10
    static let artworkInset: CGFloat = 12
    static let removeButtonOverflow: CGFloat = 4
}

struct AttachmentPreviewArtwork: View {
    let image: NSImage
    let fillsTile: Bool

    var body: some View {
        Group {
            if fillsTile {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(AttachmentPreviewMetrics.artworkInset)
            }
        }
        .frame(
            width: AttachmentPreviewMetrics.side,
            height: AttachmentPreviewMetrics.side
        )
        .attachmentPreviewSurface()
    }
}

struct AttachmentPreviewImageStrip: View {
    let images: [NSImage]

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: SnipSnapSpacing.relatedContent) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    AttachmentPreviewArtwork(image: image, fillsTile: true)
                }
            }
        }
        .frame(height: AttachmentPreviewMetrics.side)
        .scrollIndicators(.hidden)
    }
}

struct AttachmentPreviewItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let fileName: String

    init(url: URL) {
        id = url.standardizedFileURL.absoluteString
        self.url = url
        fileName = url.lastPathComponent
    }

    init(attachment: SnipAttachment, url: URL) {
        id = attachment.id.uuidString
        self.url = url
        fileName = attachment.fileName
    }
}

struct AttachmentPreviewStrip: View {
    let items: [AttachmentPreviewItem]
    let onPreview: (URL) -> Void
    var onRemove: ((AttachmentPreviewItem) -> Void)?

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: SnipSnapSpacing.relatedContent) {
                ForEach(items) { item in
                    preview(item)
                }
            }
            .padding(.top, onRemove == nil ? 0 : AttachmentPreviewMetrics.removeButtonOverflow)
            .padding(
                .trailing,
                onRemove == nil ? 0 : AttachmentPreviewMetrics.removeButtonOverflow
            )
        }
        .frame(
            height: AttachmentPreviewMetrics.side
                + (onRemove == nil ? 0 : AttachmentPreviewMetrics.removeButtonOverflow * 2)
        )
        .scrollIndicators(.hidden)
    }

    private func preview(_ item: AttachmentPreviewItem) -> some View {
        ZStack(alignment: .topTrailing) {
            AttachmentPreviewTile(
                url: item.url,
                fileName: item.fileName,
                onPreview: { onPreview(item.url) }
            )

            if let onRemove {
                Button {
                    onRemove(item)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .contentShape(.circle)
                .offset(
                    x: AttachmentPreviewMetrics.removeButtonOverflow,
                    y: -AttachmentPreviewMetrics.removeButtonOverflow
                )
                .help("Remove \(item.fileName)")
                .accessibilityLabel("Remove \(item.fileName)")
            }
        }
    }
}

private struct AttachmentPreviewTile: View {
    let url: URL
    let fileName: String
    let onPreview: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: onPreview) {
            previewImage
                .accessibilityHidden(true)
            .contentShape(
                RoundedRectangle(
                    cornerRadius: AttachmentPreviewMetrics.cornerRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .help("Quick Look \(fileName)")
        .accessibilityLabel("Preview \(fileName)")
        .accessibilityHint("Shows a Quick Look preview")
        .task(id: thumbnailRequestID) {
            thumbnail = await PreviewImageCache.shared.fileThumbnail(
                url: url,
                size: CGSize(
                    width: AttachmentPreviewMetrics.side,
                    height: AttachmentPreviewMetrics.side
                ),
                scale: displayScale
            )
        }
    }

    @ViewBuilder
    private var previewImage: some View {
        if let thumbnail {
            AttachmentPreviewArtwork(image: thumbnail, fillsTile: true)
        } else {
            Color.clear
            .frame(
                width: AttachmentPreviewMetrics.side,
                height: AttachmentPreviewMetrics.side
            )
            .attachmentPreviewSurface()
            .overlay {
                Image(systemName: "doc")
                    .font(.system(size: 24))
                    .foregroundStyle(SnipSnapColors.textSecondary)
            }
        }
    }

    private var thumbnailRequestID: String {
        "\(url.standardizedFileURL.path)|\(displayScale)"
    }
}

private extension View {
    func attachmentPreviewSurface() -> some View {
        let shape = RoundedRectangle(
            cornerRadius: AttachmentPreviewMetrics.cornerRadius,
            style: .continuous
        )
        let edge = PanelEdgeStyle.media
        return background(SnipSnapColors.attachmentFill)
            .clipShape(shape)
            .overlay {
                shape.stroke(
                    edge.color,
                    lineWidth: edge.width
                )
            }
    }
}
