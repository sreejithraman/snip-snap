import SnipSnapCore
import SwiftUI

struct ShareExtensionView: View {
    let model: ShareExtensionModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Save to Snip Snap")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: model.cancel)
                            .disabled(model.phase == .saving)
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

                Section("List") {
                    Picker("Destination", selection: Bindable(model).destinationListID) {
                        ForEach(model.lists) { list in
                            Label(list.displayName, systemImage: list.systemImage)
                                .tag(list.id)
                        }
                    }
                    .accessibilityIdentifier("share-list-picker")
                }

                Section {
                    Button("Save") {
                        Task { await model.save() }
                    }
                    .disabled(!model.canSave)
                    .accessibilityIdentifier("share-save")
                }
            }
            .disabled(model.phase == .saving)
            .overlay {
                if model.phase == .saving {
                    ProgressView("Saving…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
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
