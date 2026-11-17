import Foundation
import SnipSnapCore
import SwiftUI
import UIKit

#if DEBUG
/// Samples native page layout while XCTest's synchronous drag owns the test process.
struct PageLayoutUITestProbe: UIViewControllerRepresentable {
    let name: String

    func makeUIViewController(context: Context) -> Controller { Controller(name: name) }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.name = name
        controller.view.accessibilityIdentifier = "page-layout-\(name)"
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.displayLink?.invalidate()
    }

    final class Controller: UIViewController {
        var name: String
        var displayLink: CADisplayLink?
        private var samples: [[String: CGFloat]] = []

        init(name: String) {
            self.name = name
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func loadView() {
            let probe = ProbeView()
            probe.isAccessibilityElement = true
            probe.accessibilityIdentifier = "page-layout-\(name)"
            probe.read = { [weak self] in
                guard let self, let data = try? JSONEncoder().encode(samples) else { return "[]" }
                return String(decoding: data, as: UTF8.self)
            }
            view = probe
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            guard parent != nil, displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(sample))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func sample() {
            guard let navigationController, let window = view.window else { return }
            func collection(in view: UIView) -> UICollectionView? {
                (view as? UICollectionView) ?? view.subviews.lazy.compactMap { collection(in: $0) }.first
            }
            let pageFrame = navigationController.view.convert(navigationController.view.bounds, to: window)
            guard pageFrame.intersection(window.bounds).width > 1,
                  let list = collection(in: navigationController.view),
                  let cell = list.visibleCells.min(by: { $0.frame.minY < $1.frame.minY }) else { return }
            let toolbarCount = navigationController.topViewController?.navigationItem.trailingItemGroups
                .reduce(0) { $0 + $1.barButtonItems.count } ?? 0
            var hasVerticalBar = false
            if #available(iOS 27.1, *), let scene = window.windowScene {
                hasVerticalBar = scene.traitCollection.verticalBarEdge != .unspecified
            }
            var value: [String: CGFloat] = [
                "pageX": pageFrame.minX,
                "collectionWidth": list.bounds.width,
                "viewportHeight": list.bounds.height,
                "contentHeight": list.contentSize.height,
                "snipWidth": cell.contentView.bounds.width,
                "snipHeight": cell.contentView.bounds.height,
                "contentOffsetY": list.contentOffset.y,
                "navigationBarHeight": navigationController.navigationBar.bounds.height,
                "toolbarSlotCount": CGFloat(toolbarCount),
                "hasVerticalBar": hasVerticalBar ? 1 : 0
            ]
            func titleHeights(in view: UIView, clippedTo clip: CGRect) -> [CGFloat] {
                guard !view.isHidden, view.alpha > 0.01 else { return [] }
                let frame = view.convert(view.bounds, to: window)
                let visibleClip = view.clipsToBounds ? clip.intersection(frame) : clip
                let visible = frame.intersection(visibleClip)
                let own = (view as? UILabel).flatMap {
                    $0.text == name && !visible.isNull && !visible.isEmpty ? visible.height : nil
                }
                return (own.map { [$0] } ?? []) + view.subviews.flatMap { titleHeights(in: $0, clippedTo: visibleClip) }
            }
            if let height = titleHeights(in: navigationController.view, clippedTo: window.bounds).max() {
                value["visibleTitleHeight"] = height
            }
            if samples.last != value { samples.append(value) }
            if samples.count > 1000 { samples.removeFirst() }
        }
    }

    final class ProbeView: UIView {
        var read: (() -> String)?
        override var accessibilityValue: String? {
            get { read?() }
            set {}
        }
    }
}

actor RecoveryUITestSnipLibrary: SnipLibrary {
    private let listID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let snipID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let recoveredSnipID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let recoveredListID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private var snips: [Snip]
    private var lists: [SnipList]
    private var recovery: SnipRecoverySnapshot

    init() {
        let list = SnipList(
            id: listID,
            name: "Server Notes",
            systemImage: "folder",
            position: 1
        )
        let current = Snip(
            id: snipID,
            content: "Current text from iCloud",
            origin: .quickEntry,
            listID: listID
        )
        let recoveredValue = Snip(
            id: recoveredSnipID,
            content: "Recovered text from this device",
            origin: .quickEntry,
            source: SnipSource(applicationName: "Notes"),
            listID: listID,
            isDone: true
        )
        snips = [current]
        lists = [.inbox, list]
        recovery = SnipRecoverySnapshot(
            pendingSnips: [
                RecoveredSnip(
                    id: recoveredSnipID,
                    currentSnipID: snipID,
                    recovered: recoveredValue,
                    conflictingFields: [.text, .source, .done]
                )
            ],
            pendingLists: [
                RecoveredListEdit(
                    id: recoveredListID,
                    currentListID: listID,
                    recovered: SnipList(
                        id: listID,
                        name: "Recovered Notes",
                        systemImage: "star",
                        position: list.position,
                        sortKey: list.sortKey
                    ),
                    conflictingFields: [.name, .icon]
                )
            ]
        )
    }

    func snapshot(sortedBy sortMode: SnipSortMode) -> SnipLibrarySnapshot {
        SnipLibrarySnapshot(snips: Snip.sorted(snips, by: sortMode), lists: lists)
    }

    func checkedSnapshot(sortedBy sortMode: SnipSortMode) -> SnipLibrarySnapshot {
        snapshot(sortedBy: sortMode)
    }

    func perform(
        _ command: SnipLibraryCommand,
        sortedBy sortMode: SnipSortMode
    ) throws -> SnipLibraryUpdate {
        guard case .pruneAttachments = command else {
            throw SnipLibraryError.storeUnavailable
        }
        return SnipLibraryUpdate(snapshot: snapshot(sortedBy: sortMode), outcome: .none)
    }

    func recoverySnapshot(in scope: SnipRecoveryScope) -> SnipRecoverySnapshot {
        recovery
    }

    func resolveRecovery(
        _ id: UUID,
        in scope: SnipRecoveryScope,
        choice: SnipRecoveryChoice
    ) throws -> SnipLibrarySnapshot {
        if let pending = recovery.pendingSnips.first(where: { $0.id == id }) {
            try resolve(pending, choice: choice)
            recovery = SnipRecoverySnapshot(
                promotedSnips: recovery.promotedSnips,
                pendingLists: recovery.pendingLists
            )
        } else if let pending = recovery.pendingLists.first(where: { $0.id == id }) {
            try resolve(pending, choice: choice)
            recovery = SnipRecoverySnapshot(
                pendingSnips: recovery.pendingSnips,
                promotedSnips: recovery.promotedSnips
            )
        } else {
            throw SnipLibraryError.recoveryNotFound
        }
        return snapshot(sortedBy: .chronological)
    }

    private func resolve(_ pending: RecoveredSnip, choice: SnipRecoveryChoice) throws {
        guard let index = snips.firstIndex(where: { $0.id == pending.currentSnipID }) else {
            throw SnipLibraryError.recoveryChanged
        }
        switch choice {
        case .keepCurrent:
            break
        case .useRecovered:
            snips[index] = applying(pending.recovered, to: snips[index], fields: pending.conflictingFields)
        case .keepBoth:
            snips.append(pending.recovered)
            recovery = SnipRecoverySnapshot(
                pendingSnips: recovery.pendingSnips,
                promotedSnips: recovery.promotedSnips + [pending.promoted()],
                pendingLists: recovery.pendingLists
            )
        case .editSnip(let edited):
            snips[index] = applying(edited, to: snips[index], fields: pending.conflictingFields)
        case .editList:
            throw SnipLibraryError.invalidRecoveryChoice
        }
    }

    private func resolve(_ pending: RecoveredListEdit, choice: SnipRecoveryChoice) throws {
        guard let index = lists.firstIndex(where: { $0.id == pending.currentListID }) else {
            throw SnipLibraryError.recoveryChanged
        }
        switch choice {
        case .keepCurrent:
            break
        case .useRecovered:
            lists[index] = applying(pending.recovered, to: lists[index], fields: pending.conflictingFields)
        case .editList(let edited):
            lists[index] = applying(edited, to: lists[index], fields: pending.conflictingFields)
        case .keepBoth, .editSnip:
            throw SnipLibraryError.invalidRecoveryChoice
        }
    }

    private func applying(
        _ candidate: Snip,
        to current: Snip,
        fields: Set<RecoveredSnipField>
    ) -> Snip {
        var result = current
        if fields.contains(.text) { result.content = candidate.content }
        if fields.contains(.source) { result.source = candidate.source }
        if fields.contains(.done) { result.isDone = candidate.isDone }
        if fields.contains(.placement) { result.listID = candidate.listID }
        return result
    }

    private func applying(
        _ candidate: SnipList,
        to current: SnipList,
        fields: Set<RecoveredListField>
    ) -> SnipList {
        SnipList(
            id: current.id,
            name: fields.contains(.name) ? candidate.name : current.name,
            systemImage: fields.contains(.icon) ? candidate.systemImage : current.systemImage,
            position: current.position,
            sortKey: current.sortKey
        )
    }
}
#endif

#if DEBUG
actor UITestAppleAccountCacheHandler: AppleAccountCacheHandling {
    private var didResolve = false
    func refreshAppleAccountNotice() async throws -> AppleAccountNotice? {
        didResolve ? nil : .signedOut
    }
    func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {
        didResolve = true
    }
}
#endif

#if DEBUG
@MainActor
func seedListHistoryUITestFixture(in model: IOSAppModel) async {
    guard ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_LIST_HISTORY"] == "1" else { return }
    for name in ["Scale 07", "Scale 08"] {
        _ = await model.createList(name: name)
    }
    if let work = model.lists.first(where: { $0.name == "Work" }) {
        _ = await model.createSnip(content: "Work history note", in: work.id)
    }
}
#endif
