import SnipSnapCore
import SwiftUI
import UIKit

func listAppearance(for snip: Snip, in lists: [SnipList]) -> SnipListAppearance {
    (lists.first { $0.id == snip.listID } ?? .inbox).accent
}

struct SnipRow: View {
    let snip: Snip
    let model: IOSAppModel
    let isRecovered: Bool
    var showsStatusIcon = true
    var showsPinInMetadata = true
    var allowsTextExpansion = true
    var isGathering = false
    var isReordering = false
    var sourceFrameChanged: ((CGRect) -> Void)? = nil
    @State private var isChangingCompletion = false
    var onPreviewAttachment: ((SnipAttachment) -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    var onToggleDone: (() async -> Bool)? = nil

    private var appearance: SnipListAppearance {
        listAppearance(for: snip, in: model.lists)
    }

    var body: some View {
        IOSItemRow(hasLeading: showsStatusIcon || isGathering) {
            if isGathering {
                SnipCompletionIcon(isDone: snip.isDone, appearance: appearance)
                    .opacity(0.35)
                    .accessibilityHidden(true)
            } else if showsStatusIcon {
                if snip.isPinned, let onCopy {
                    SnipCopyControl(appearance: appearance, isPinned: true, action: onCopy)
                    .accessibilityLabel("Copy Pinned Snip")
                    .accessibilityIdentifier("copy-pinned-snip-\(snip.id)")
                } else {
                    Button {
                        guard !isChangingCompletion else { return }
                        isChangingCompletion = true
                        Task { @MainActor in
                            if let onToggleDone {
                                _ = await onToggleDone()
                            } else {
                                _ = await model.toggleDone(id: snip.id)
                            }
                            isChangingCompletion = false
                        }
                    } label: {
                        SnipCompletionIcon(isDone: snip.isDone, appearance: appearance)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isChangingCompletion)
                    .accessibilityLabel(SnipCompletionLanguage.menuActionTitle(isDone: snip.isDone))
                    .accessibilityValue(SnipCompletionLanguage.stateTitle(isDone: snip.isDone))
                    .accessibilityIdentifier("completion-\(snip.id)")
                }
            }
        } content: {
            SnipContentView(
                snip: snip,
                model: model,
                isRecovered: isRecovered,
                allowsTextExpansion: allowsTextExpansion && !isReordering && !isGathering,
                onPreviewAttachment: onPreviewAttachment,
                showsPin: showsPinInMetadata && (isGathering || !showsStatusIcon || onCopy == nil)
            )
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sourceFrameChanged?($0) }
        // Give the native reorder handle the snip's name.
        .accessibilityElement(children: isReordering ? .ignore : (onPreviewAttachment == nil ? .combine : .contain))
        .accessibilityLabel(SnipContentView.accessibilityLabel(for: snip))
        .accessibilityValue(
            snip.isPinned ? String(localized: "Pinned") : SnipCompletionLanguage.stateTitle(isDone: snip.isDone)
        )
    }
}

/// Shared content for source rows and selected glass cards. Controls belong to the host.
struct SnipContentView: View {
    let snip: Snip
    let model: IOSAppModel
    let isRecovered: Bool
    var lineLimit: Int? = 3
    var loadsAttachmentPreviews = true
    var allowsTextExpansion = false
    var onPreviewAttachment: ((SnipAttachment) -> Void)? = nil
    var showsPin = true

    static func accessibilityLabel(for snip: Snip) -> String {
        let text = snip.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = snip.attachments.map(\.fileName).joined(separator: ", ")
        return [
            text.isEmpty ? nil : text,
            snip.origin == .agent
                ? AgentSnipContextLanguage.accessibilityLabel(snip.agentContextLabel)
                : nil,
            attachments.isEmpty ? nil : String(localized: "Attachments: \(attachments)"),
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    private var hasVisibleText: Bool {
        !snip.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ItemRowContent {
            if hasVisibleText {
                ItemRowText(
                    text: snip.content,
                    lineLimit: lineLimit,
                    isDone: snip.isDone,
                    allowsExpansion: allowsTextExpansion,
                    accessibilityIdentifier: "snip-text-\(snip.id)"
                )
            }
        } previews: {
            attachmentPreviews
        } metadata: {
            SnipRowMetadata(
                date: snip.updatedAt,
                isPinned: snip.isPinned,
                isAgent: snip.origin == .agent,
                agentContextLabel: snip.agentContextLabel,
                isRecovered: isRecovered,
                showsPin: showsPin
            )
        }
    }

    @ViewBuilder
    private var attachmentPreviews: some View {
        if !snip.attachments.isEmpty {
            CompactItemPreviews(items: snip.attachments) { attachment in
                if !loadsAttachmentPreviews {
                    // Preserve measurement without starting work for a hidden card.
                    Color.clear.accessibilityHidden(true)
                } else if let onPreviewAttachment {
                    CompactAttachmentPreviewButton(
                        attachment: attachment,
                        model: model,
                        action: { onPreviewAttachment(attachment) }
                    )
                } else {
                    AttachmentStatusThumbnail(attachment: attachment, model: model)
                }
            }
        }
    }

}

private struct CompactAttachmentPreviewButton: View {
    let attachment: SnipAttachment
    let model: IOSAppModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AttachmentStatusThumbnail(attachment: attachment, model: model)
                .frame(width: 64, height: 64)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Preview \(attachment.fileName)")
        .accessibilityIdentifier("compact-attachment-preview-\(attachment.fileName)")
    }
}

private struct AttachmentStatusThumbnail: View {
    let attachment: SnipAttachment
    let model: IOSAppModel

    var body: some View {
        Group {
            if let url = model.usableAttachmentURL(for: attachment.id) {
                AttachmentThumbnail(url: url)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    switch model.attachmentTransferState(for: attachment.id) {
                    case .syncing:
                        ProgressView()
                    case .failed:
                        Image(systemName: "exclamationmark.icloud")
                            .foregroundStyle(.red)
                    case .waiting:
                        Image(systemName: "icloud")
                            .foregroundStyle(.secondary)
                    case .available:
                        Image(systemName: "icloud.and.arrow.down")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("\(attachment.fileName), \(stateLabel)")
        .modifier(VisibleAttachmentPreparation(
            attachmentID: attachment.id,
            fileName: attachment.fileName,
            contentType: attachment.contentType,
            model: model
        ))
    }

    private var stateLabel: String {
        switch model.attachmentTransferState(for: attachment.id) {
        case .waiting: String(localized: "waiting for iCloud")
        case .syncing: String(localized: "syncing")
        case .failed: String(localized: "failed")
        case .available: String(localized: "available")
        }
    }
}

struct SnipCompletionIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 28
    let isDone: Bool
    let appearance: SnipListAppearance

    var body: some View {
        Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isDone)
            .font(.system(size: diameter))
            .foregroundStyle(appearance.controlTint)
            .frame(width: max(44, diameter), height: max(44, diameter))
            .contentShape(Rectangle())
    }
}

struct SnipCopyControl: View {
    let appearance: SnipListAppearance
    var isPinned = false
    let action: () -> Void

    init(appearance: SnipListAppearance = SnipListAppearance(preset: nil), isPinned: Bool = false, action: @escaping () -> Void) {
        self.appearance = appearance
        self.isPinned = isPinned
        self.action = action
    }

    var body: some View {
        SnipCircularControl(systemImage: isPinned ? "pin.fill" : "doc.on.doc", appearance: appearance, action: action)
    }
}

/// Shared visual language for row copy and gathered-item return controls.
struct SnipCircularControl: View {
    let systemImage: String
    let appearance: SnipListAppearance
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SnipCircularControlLabel(systemImage: systemImage, appearance: appearance)
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }
}

/// The transfer uses the same return-control drawing as its eventual button.
struct SnipCircularControlLabel: View {
    @ScaledMetric(relativeTo: .body) private var controlDiameter: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var symbolSize: CGFloat = 13
    let systemImage: String
    let appearance: SnipListAppearance

    var body: some View {
        ZStack {
            Circle().fill(appearance.controlTint)
            Image(systemName: systemImage)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(Color(uiColor: .systemBackground))
        }
        .frame(width: controlDiameter, height: controlDiameter)
        .frame(width: max(44, controlDiameter), height: max(44, controlDiameter))
        .contentShape(Rectangle())
    }
}

/// Controls keep the same slot and the text starts on the same baseline.
struct IOSItemRow<Leading: View, Content: View>: View {
    var hasLeading = true
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            leading()
            content()
                .padding(.top, hasLeading ? SnipSnapSpacing.relatedContent : 0)
        }
        .padding(.vertical, 4)
    }
}

struct CompactItemPreviews<Item: Identifiable, Preview: View>: View {
    let items: [Item]
    @ViewBuilder let preview: (Item) -> Preview

    var body: some View {
        if !items.isEmpty {
            HStack(spacing: SnipSnapSpacing.relatedContent) {
                ForEach(Array(items.prefix(3))) { item in
                    preview(item)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if items.count > 3 {
                    Text("+\(items.count - 3)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
