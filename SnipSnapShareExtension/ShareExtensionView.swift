import SnipSnapCore
import SwiftUI

struct ShareExtensionView: View {
    let model: ShareExtensionModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(.saveToSnipSnap)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(.cancel, action: model.cancel)
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
            ProgressView(.loadingSharedContent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("share-loading")
        case .editing, .saving:
            Form {
                Section(.preview) {
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

                Section(.listGenericName) {
                    Picker(.destination, selection: Bindable(model).destinationListID) {
                        ForEach(model.lists) { list in
                            Label(list.displayName, systemImage: list.systemImage)
                                .tag(list.id)
                        }
                    }
                    .accessibilityIdentifier("share-list-picker")
                }

                Section {
                    Button(.save) {
                        Task { await model.save() }
                    }
                    .disabled(!model.canSave)
                    .accessibilityIdentifier("share-save")
                }
            }
            .disabled(model.phase == .saving)
            .overlay {
                if model.phase == .saving {
                    ProgressView(.saving)
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        case .failed(let message):
            ContentUnavailableView(
                .couldNotSave,
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .accessibilityIdentifier("share-error")
        }
    }
}
