import SnipSnapCore
import SwiftUI

private enum MacRecoveryRoute: Equatable {
    case snip(UUID)
    case list(UUID)
}

struct MacRecoveryReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var route: MacRecoveryRoute?

    var body: some View {
        NavigationStack {
            Group {
                switch route {
                case .snip(let id):
                    MacRecoveredSnipReview(model: model, recoveryID: id, route: $route)
                case .list(let id):
                    MacRecoveredListReview(model: model, recoveryID: id, route: $route)
                case nil:
                    recoveryList
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(route == nil ? "Done" : "Back") {
                        if route == nil { dismiss() } else { route = nil }
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .task {
            while !Task.isCancelled {
                await model.refreshRecovery()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var recoveryList: some View {
        List {
            if !model.pendingRecoveredSnips.isEmpty {
                Section("Recovered snips") {
                    ForEach(model.pendingRecoveredSnips) { recovery in
                        Button {
                            route = .snip(recovery.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(
                                    recovery.recovered.content.isEmpty
                                        ? "Recovered snip"
                                        : SnipTextPreview.displayText(
                                            recovery.recovered.content,
                                            lineLimit: 2
                                        )
                                )
                                    .lineLimit(2)
                                Text("Recovered snip")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !model.pendingRecoveredLists.isEmpty {
                Section("Recovered lists") {
                    ForEach(model.pendingRecoveredLists) { recovery in
                        Button {
                            route = .list(recovery.id)
                        } label: {
                            Label(recovery.recovered.name, systemImage: recovery.recovered.systemImage)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if model.needsAttentionCount == 0 {
                ContentUnavailableView("Nothing to review", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("Needs attention")
    }
}

private struct MacRecoveredSnipReview: View {
    @ObservedObject var model: AppModel
    let recoveryID: UUID
    @Binding var route: MacRecoveryRoute?
    @State private var edited: Snip?
    @State private var isResolving = false

    private var recovery: RecoveredSnip? {
        model.pendingRecoveredSnips.first { $0.id == recoveryID }
    }

    var body: some View {
        Group {
            if let recovery, let current = model.currentSnip(for: recovery) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .top, spacing: 16) {
                            values("Current version", snip: current, fields: recovery.conflictingFields)
                            values("Recovered version", snip: recovery.recovered, fields: recovery.conflictingFields)
                        }
                        editFields(recovery)
                        HStack {
                            Button("Keep current") { resolve(.keepCurrent) }
                            Button("Keep both") { resolve(.keepBoth) }
                            Spacer()
                            Button("Use recovered") { resolve(.useRecovered) }
                                .buttonStyle(.borderedProminent)
                            Button("Use edited version") {
                                if let edited { resolve(.editSnip(edited)) }
                            }
                        }
                    }
                    .padding(24)
                }
                .disabled(isResolving)
                .onAppear { if edited == nil { edited = recovery.recovered } }
            } else {
                ContentUnavailableView("Recovered version unavailable", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("Recovered snip")
    }

    private func values(
        _ title: String,
        snip: Snip,
        fields: Set<RecoveredSnipField>
    ) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 10) {
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
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func editFields(_ recovery: RecoveredSnip) -> some View {
        if let binding = Binding($edited) {
            GroupBox("Edit differences") {
                VStack(alignment: .leading, spacing: 10) {
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
            if await model.resolveRecovery(recoveryID, choice: choice) { route = nil }
            isResolving = false
        }
    }
}

private struct MacRecoveredListReview: View {
    @ObservedObject var model: AppModel
    let recoveryID: UUID
    @Binding var route: MacRecoveryRoute?
    @State private var edited: SnipList?
    @State private var isResolving = false

    private var recovery: RecoveredListEdit? {
        model.pendingRecoveredLists.first { $0.id == recoveryID }
    }

    var body: some View {
        Group {
            if let recovery, let current = model.currentList(for: recovery) {
                Form {
                    Section("Current version") { values(current, fields: recovery.conflictingFields) }
                    Section("Recovered version") { values(recovery.recovered, fields: recovery.conflictingFields) }
                    if let binding = Binding($edited) {
                        Section("Edit differences") {
                            if recovery.conflictingFields.contains(.name) {
                                TextField("Name", text: binding.name)
                            }
                            if recovery.conflictingFields.contains(.icon) {
                                TextField("Symbol", text: binding.systemImage)
                            }
                        }
                    }
                    HStack {
                        Button("Keep current") { resolve(.keepCurrent) }
                        Spacer()
                        Button("Use recovered") { resolve(.useRecovered) }
                            .buttonStyle(.borderedProminent)
                        Button("Use edited version") {
                            if let edited { resolve(.editList(edited)) }
                        }
                    }
                }
                .formStyle(.grouped)
                .disabled(isResolving)
                .onAppear { if edited == nil { edited = recovery.recovered } }
            } else {
                ContentUnavailableView("Recovered version unavailable", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("Recovered list")
    }

    @ViewBuilder
    private func values(_ list: SnipList, fields: Set<RecoveredListField>) -> some View {
        if fields.contains(.name) { LabeledContent("Name", value: list.name) }
        if fields.contains(.icon) { Label(list.systemImage, systemImage: list.systemImage) }
        if fields.contains(.color) {
            Label(list.accent.title, systemImage: "circle.fill").foregroundStyle(list.accent.color)
        }
    }

    private func resolve(_ choice: SnipRecoveryChoice) {
        isResolving = true
        Task {
            if await model.resolveRecovery(recoveryID, choice: choice) { route = nil }
            isResolving = false
        }
    }
}
