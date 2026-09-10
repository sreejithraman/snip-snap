import SwiftUI

struct AccessibilitySetupCard: View {
    @ObservedObject var controller: AccessibilityPermissionController

    var body: some View {
        let presentation = controller.setupCardState.presentation
        PanelContentCard {
            Image(systemName: "accessibility")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SnipSnapColors.textSecondary)
                .frame(width: 32, height: 32)
                .background(SnipSnapColors.compactSubduedFill, in: Circle())
                .accessibilityHidden(true)
        } main: {
            VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
                Text(presentation.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SnipSnapColors.textPrimary)

                Text(presentation.message)
                    .font(.caption)
                    .foregroundStyle(SnipSnapColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: SnipSnapSpacing.relatedContent) {
                    Spacer(minLength: 0)
                    Button("Later") {
                        controller.deferSetup()
                    }
                    .buttonStyle(.borderless)

                    AccessibilityActionButton(title: presentation.primaryActionTitle) {
                        controller.performPrimaryAction()
                    }
                }
                .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
    }

}

struct AccessibilityRepairView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: AccessibilityPermissionController

    var body: some View {
        let presentation = controller.setupCardState.presentation
        VStack(alignment: .leading, spacing: SnipSnapSpacing.paneContentInset) {
            Label("Accessibility Access Needed", systemImage: "accessibility")
                .font(.headline)

            Text(
                "Capture Selection and global Shift shortcuts need Accessibility access. You can keep using other parts of Snip Snap without it."
            )
            .foregroundStyle(SnipSnapColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if presentation.showsRepairInstructions {
                Text(AccessibilitySetupCardState.repairInstructions)
                .font(.caption)
                .foregroundStyle(SnipSnapColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: SnipSnapSpacing.relatedContent) {
                Spacer()
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                AccessibilityActionButton(title: presentation.primaryActionTitle) {
                    dismiss()
                    controller.performPrimaryAction()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(SnipSnapSpacing.paneContentInset)
        .frame(width: 380)
    }
}

private struct AccessibilityActionButton: View {
    @Environment(\.controlActiveState) private var controlActiveState
    let title: String
    let action: () -> Void

    var body: some View {
        if controlActiveState == .inactive {
            Button(title, action: action)
                .buttonStyle(InactiveAccessibilityActionButtonStyle())
        } else {
            AppProminentActionButton(action: action) {
                Text(title)
                    .foregroundStyle(SnipSnapTheme.prominentControlLabel)
            }
        }
    }
}

private struct InactiveAccessibilityActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(SnipSnapColors.textSecondary)
            .padding(.horizontal, SnipSnapSpacing.relatedContent)
            .padding(.vertical, 4)
            .background(SnipSnapColors.compactSubduedFill, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
