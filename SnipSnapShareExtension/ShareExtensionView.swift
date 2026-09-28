import SnipSnapCore
import SwiftUI

struct ShareExtensionView: View {
    let model: ShareExtensionModel

    @Environment(\.colorScheme) private var colorScheme

    private var destinationAccent: SnipListAppearance {
        model.destinationList?.accent ?? SnipListAppearance(preset: nil)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Save to Snip Snap")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: model.cancel) {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Cancel")
                        .disabled(model.phase == .saving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if model.phase == .saving {
                            ProgressView()
                                .accessibilityLabel("Saving…")
                        } else {
                            AppPrimaryActionButton(
                                presentation: .floatingGlass,
                                tint: destinationAccent.controlTint,
                                labelColor: destinationAccent.sendIconColor(in: colorScheme),
                                action: { Task { await model.save() } }
                            ) {
                                Text("Save")
                                    .fontWeight(.semibold)
                            }
                            .disabled(!model.canSave)
                            .accessibilityIdentifier("share-save")
                        }
                    }
                }
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading shared content…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("share-loading")
        case .editing, .saving:
            Form {
                Section("Preview") {
                    TextEditor(text: Bindable(model).content)
                        .frame(minHeight: 112)
                        .accessibilityIdentifier("share-text")

                    ForEach(model.attachments, id: \.relativePath) { attachment in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(attachment.fileName)
                                    .lineLimit(1)
                                Text(
                                    ByteCountFormatter.string(
                                        fromByteCount: attachment.byteCount,
                                        countStyle: .file
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Save to") {
                    Picker("List", selection: Bindable(model).destinationListID) {
                        ForEach(model.lists) { list in
                            Label(list.displayName, systemImage: list.systemImage)
                                .tag(list.id)
                        }
                    }
                    .accessibilityIdentifier("share-list-picker")
                }
            }
            .disabled(model.phase == .saving)
        case .failed(let message):
            ContentUnavailableView(
                "Could Not Save",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .accessibilityIdentifier("share-error")
        }
    }
}
