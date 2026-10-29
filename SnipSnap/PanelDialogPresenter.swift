import AppKit
import SnipSnapCore
import SwiftUI

struct PanelDialogContent<Content: View>: View {
    @ObservedObject var model: AppModel
    let showsModelErrors: Bool
    let content: Content

    var body: some View {
        content
            .safeAreaInset(edge: .bottom) {
                if showsModelErrors {
                    PanelFailureNotices(model: model)
                }
            }
            .panelDialogToast(model: model, isHidden: showsModelErrors && model.dialogFailure != nil)
            .sheet(item: Binding<AppFailure?>(
                get: { showsModelErrors ? model.dialogFailure : nil },
                set: { if $0 == nil { model.dismissErrorDetails() } }
            )) { failure in
                AppErrorDetailsView(failure: failure, onClose: { model.dismissErrorDetails(failure) },
                                    onRetry: model.errorRetryAction)
                    .panelDialogToast(model: model)
            }
    }
}

private extension View {
    func panelDialogToast(model: AppModel, isHidden: Bool = false) -> some View {
        let showsInspectedFailure = if case .showErrorDetails(let id) = model.toast?.action {
            model.dialogFailure?.id == id
        } else { false }
        return appToast(
            Binding(get: { model.toast }, set: { model.toast = $0 }),
            alignment: .bottom, edge: .bottom,
            isHidden: isHidden || showsInspectedFailure, reservesSpace: true,
            onAction: model.performToastAction, onDismiss: model.dismissToast
        )
    }
}

struct PanelErrorDialog: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let failure = model.dialogFailure {
            AppErrorDetailsView(failure: failure, onClose: { model.dismissErrorDetails(failure) },
                                    onRetry: model.errorRetryAction)
        }
    }
}

struct PanelFailureNotices: View {
    @ObservedObject var model: AppModel

    @ViewBuilder var body: some View {
        if model.inlineFailure != nil || model.pendingUndoFailure != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let failure = model.inlineFailure {
                    PanelInlineFailureView(model: model, failure: failure)
                }
                if let failure = model.pendingUndoFailure {
                    AppUndoRecoveryView(
                        failure: failure,
                        onRetry: { model.retryPendingUndo(failure) },
                        onDetails: { model.errorDetails = failure }
                    )
                }
            }
        }
    }
}

struct PanelInlineFailureView: View {
    @ObservedObject var model: AppModel
    let failure: AppFailure

    var body: some View {
        VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
            Label(failure.title, systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
            Text(failure.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Details", action: model.showLatestErrorDetails)
                Button("Dismiss", action: model.dismissPresentedError)
            }
            .buttonStyle(.borderless)
        }
        .padding(SnipSnapSpacing.paneContentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inline-failure")
    }
}

struct PanelConfirmationDialog: View {
    let title: String
    let message: String
    let confirmTitle: String
    var isDestructive = false
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SnipSnapSpacing.paneContentInset) {
            Text(title)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if isDestructive {
                    Button(confirmTitle, role: .destructive, action: onConfirm)
                        .buttonStyle(.bordered)
                } else {
                    AppPrimaryActionButton(action: onConfirm) {
                        Text(confirmTitle)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(SnipSnapSpacing.paneContentInset)
    }
}

private struct PanelDialogSurface: View {
    let content: AnyView

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: PanelShapeMetrics.paneCornerRadius,
            style: .continuous
        )
        content
            .frame(width: PanelDialogMetrics.width)
            .background(Color(nsColor: .windowBackgroundColor), in: shape)
            .clipShape(shape)
    }
}

@MainActor
enum PanelDialogDismissalReason {
    case close
    case parentHide
}

private final class PanelDialogWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelDialogPresenter {
    private var id: PanelDialogID?
    private weak var parentWindow: NSWindow?
    private var windowController: NSWindowController?
    private var onDismiss: ((PanelDialogDismissalReason) -> Void)?
    private var parentFrameObservers: [NSObjectProtocol] = []

    var isKeyWindow: Bool {
        windowController?.window?.isKeyWindow == true
    }

    func present(
        id: PanelDialogID,
        title: String,
        parent: NSWindow,
        content: AnyView,
        onDismiss: @escaping (PanelDialogDismissalReason) -> Void
    ) {
        guard windowController == nil else { return }

        let hostingController = NSHostingController(
            rootView: PanelDialogSurface(content: content)
        )
        let window = PanelDialogWindow(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.appearance = parent.appearance
        window.animationBehavior = .utilityWindow
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController

        hostingController.view.layoutSubtreeIfNeeded()
        let size = hostingController.view.fittingSize
        window.setContentSize(size)

        self.parentWindow = parent
        self.id = id
        self.onDismiss = onDismiss
        windowController = NSWindowController(window: window)

        position(window, over: parent)
        parent.addChildWindow(window, ordered: .above)
        (parent as? SnipSnapPanel)?.setPresentedModalWindow(window)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            parentFrameObservers.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: parent,
                    queue: .main
                ) { [weak self, weak window, weak parent] _ in
                    Task { @MainActor [weak self, weak window, weak parent] in
                        guard let self, let window, let parent,
                              self.windowController?.window === window else { return }
                        self.position(window, over: parent)
                    }
                }
            )
        }
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss(id: PanelDialogID, restoringParent: Bool = true) {
        guard self.id == id else { return }
        dismissCurrent(restoringParent: restoringParent)
    }

    func dismissForParentHide() {
        dismissCurrent(restoringParent: false, reason: .parentHide)
    }

    private func dismissCurrent(
        restoringParent: Bool = true,
        reason: PanelDialogDismissalReason = .close
    ) {
        guard let window = windowController?.window else { return }
        finishDismissal(for: window, restoringParent: restoringParent, reason: reason)
    }

    private func position(_ window: NSWindow, over parent: NSWindow) {
        window.setFrameOrigin(
            NSPoint(
                x: parent.frame.midX - window.frame.width / 2,
                y: parent.frame.midY - window.frame.height / 2
            )
        )
    }

    private func finishDismissal(
        for window: NSWindow,
        restoringParent: Bool,
        reason: PanelDialogDismissalReason
    ) {
        guard windowController?.window === window else { return }
        let callback = onDismiss
        for observer in parentFrameObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        parentFrameObservers.removeAll()
        if let parentWindow {
            parentWindow.removeChildWindow(window)
            (parentWindow as? SnipSnapPanel)?.setPresentedModalWindow(nil)
        }
        window.close()
        if restoringParent, parentWindow?.isVisible == true {
            parentWindow?.makeKeyAndOrderFront(nil)
        }
        windowController = nil
        parentWindow = nil
        id = nil
        onDismiss = nil
        callback?(reason)
    }
}
