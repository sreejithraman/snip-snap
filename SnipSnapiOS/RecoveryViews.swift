import SnipSnapCore
import SwiftUI

struct RecoveredSnipRow: View {
    let recovery: RecoveredSnip

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(recovery.recovered.content.isEmpty ? "Recovered edit" : recovery.recovered.content)
                .lineLimit(3)
                .foregroundStyle(.primary)
            Label("Recovered", systemImage: "arrow.uturn.backward.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        }
        .padding(.vertical, 4)
    }
}

struct RecoveryCenterView: View {
    @Environment(\.dismiss) private var dismiss
    let model: IOSAppModel

    var body: some View {
        NavigationStack {
            List {
                if !model.recoverySnapshot.pendingSnips.isEmpty {
                    Section("Recovered Snips") {
                        ForEach(model.recoverySnapshot.pendingSnips) { recovery in
                            NavigationLink {
                                RecoveredSnipReviewView(model: model, recoveryID: recovery.id)
                            } label: {
                                RecoveredSnipRow(recovery: recovery)
                            }
                        }
                    }
                }
                if !model.recoverySnapshot.pendingLists.isEmpty {
                    Section("Recovered List Edits") {
                        ForEach(model.recoverySnapshot.pendingLists) { recovery in
                            NavigationLink {
                                RecoveredListReviewView(model: model, recoveryID: recovery.id)
                            } label: {
                                Label(recovery.recovered.name, systemImage: recovery.recovered.systemImage)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Needs Attention")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct RecoveredSnipReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let model: IOSAppModel
    let recoveryID: UUID
    @State private var edited: Snip?
    @State private var isResolving = false

    private var recovery: RecoveredSnip? {
        model.recoverySnapshot.pendingSnips.first { $0.id == recoveryID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let recovery, let current = model.currentSnip(for: recovery) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            recoverySnipCard("Current", snip: current, fields: recovery.conflictingFields)
                            recoverySnipCard(
                                "Recovered Edit",
                                snip: recovery.recovered,
                                fields: recovery.conflictingFields
                            )
                            editSnipFields(recovery)
                        }
                        .padding(24)
                    }
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 12) {
                            HStack {
                                Button("Keep Current") { resolve(.keepCurrent) }
                                Spacer()
                                Button("Use Recovered") { resolve(.useRecovered) }
                                    .buttonStyle(.borderedProminent)
                            }
                            HStack {
                                Button("Keep Both") { resolve(.keepBoth) }
                                Spacer()
                                Button("Edit") {
                                    if let edited { resolve(.editSnip(edited)) }
                                }
                            }
                        }
                        .padding(16)
                        .background(.regularMaterial)
                    }
                    .disabled(isResolving)
                    .onAppear { if edited == nil { edited = recovery.recovered } }
                } else {
                    ContentUnavailableView("Recovered Edit Is Gone", systemImage: "checkmark.circle")
                }
            }
            .navigationTitle("Recovered Snip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    await model.load()
                }
            }
        }
    }

    private func recoverySnipCard(
        _ title: String,
        snip: Snip,
        fields: Set<RecoveredSnipField>
    ) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 12) {
                if fields.contains(.text) { LabeledContent("Text", value: snip.content) }
                if fields.contains(.source) {
                    LabeledContent("Source", value: snip.source?.conciseLabel ?? String(localized: "None"))
                }
                if fields.contains(.done) {
                    LabeledContent(
                        "State",
                        value: SnipCompletionLanguage.stateTitle(isDone: snip.isDone)
                    )
                }
                if fields.contains(.placement) {
                    LabeledContent(
                        "List",
                        value: model.lists.first { $0.id == snip.listID }?.displayName
                            ?? String(localized: "Inbox")
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func editSnipFields(_ recovery: RecoveredSnip) -> some View {
        if let binding = Binding($edited) {
            GroupBox("Edit Conflicting Fields") {
                VStack(alignment: .leading, spacing: 12) {
                    if recovery.conflictingFields.contains(.text) {
                        TextField("Text", text: binding.content, axis: .vertical)
                            .lineLimit(3...8)
                    }
                    if recovery.conflictingFields.contains(.source) {
                        TextField(
                            "Source app",
                            text: Binding(
                                get: { binding.wrappedValue.source?.applicationName ?? "" },
                                set: { value in
                                    var source = binding.wrappedValue.source
                                        ?? SnipSource(applicationName: "")
                                    source.applicationName = value
                                    binding.wrappedValue.source = cleaned(source)
                                }
                            )
                        )
                        sourceField("Window", keyPath: \.windowTitle, snip: binding)
                        sourceField("URL", keyPath: \.url, snip: binding)
                    }
                    if recovery.conflictingFields.contains(.done) {
                        Toggle(SnipCompletionLanguage.done, isOn: binding.isDone)
                    }
                    if recovery.conflictingFields.contains(.placement) {
                        Picker("List", selection: binding.listID) {
                            ForEach(model.lists) { Text($0.displayName).tag($0.id) }
                        }
                    }
                }
            }
        }
    }

    private func sourceField(
        _ title: String,
        keyPath: WritableKeyPath<SnipSource, String?>,
        snip: Binding<Snip>
    ) -> some View {
        TextField(
            title,
            text: Binding(
                get: { snip.wrappedValue.source?[keyPath: keyPath] ?? "" },
                set: { value in
                    var source = snip.wrappedValue.source ?? SnipSource(applicationName: "")
                    source[keyPath: keyPath] = value.isEmpty ? nil : value
                    snip.wrappedValue.source = cleaned(source)
                }
            )
        )
    }

    private func cleaned(_ source: SnipSource) -> SnipSource? {
        source.applicationName.isEmpty && source.windowTitle == nil && source.url == nil
            ? nil : source
    }

    private func resolve(_ choice: SnipRecoveryChoice) {
        isResolving = true
        Task {
            if await model.resolveRecovery(recoveryID, choice: choice) { dismiss() }
            isResolving = false
        }
    }
}

struct RecoveredListReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let model: IOSAppModel
    let recoveryID: UUID
    @State private var edited: SnipList?
    @State private var isResolving = false

    private var recovery: RecoveredListEdit? {
        model.recoverySnapshot.pendingLists.first { $0.id == recoveryID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let recovery, let current = model.currentList(for: recovery) {
                    Form {
                        Section("Current List") { listValues(current, fields: recovery.conflictingFields) }
                        Section("Recovered Edit") {
                            listValues(recovery.recovered, fields: recovery.conflictingFields)
                        }
                        if let binding = Binding($edited) {
                            Section("Edit Conflicting Fields") {
                                if recovery.conflictingFields.contains(.name) {
                                    TextField("Name", text: binding.name)
                                }
                                if recovery.conflictingFields.contains(.icon) {
                                    SnipListIconPicker(selection: binding.systemImage)
                                }
                            }
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        HStack {
                            Button("Keep Current") { resolve(.keepCurrent) }
                            Spacer()
                            Button("Use Recovered") { resolve(.useRecovered) }
                                .buttonStyle(.borderedProminent)
                            Button("Edit") {
                                if let edited { resolve(.editList(edited)) }
                            }
                        }
                        .padding(16)
                        .background(.regularMaterial)
                    }
                    .disabled(isResolving)
                    .onAppear { if edited == nil { edited = recovery.recovered } }
                } else {
                    ContentUnavailableView("Recovered Edit Is Gone", systemImage: "checkmark.circle")
                }
            }
            .navigationTitle("Recovered List Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    await model.load()
                }
            }
        }
    }

    @ViewBuilder
    private func listValues(_ list: SnipList, fields: Set<RecoveredListField>) -> some View {
        if fields.contains(.name) { LabeledContent("Name", value: list.name) }
        if fields.contains(.icon) { Label(list.systemImage, systemImage: list.systemImage) }
    }

    private func resolve(_ choice: SnipRecoveryChoice) {
        isResolving = true
        Task {
            if await model.resolveRecovery(recoveryID, choice: choice) { dismiss() }
            isResolving = false
        }
    }
}
