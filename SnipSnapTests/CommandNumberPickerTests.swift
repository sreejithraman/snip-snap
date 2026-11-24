import XCTest
import AppKit
import Carbon.HIToolbox
import Combine
@testable import SnipSnap

@MainActor
final class CommandNumberPickerTests: XCTestCase {
    func testVisibleTargetsUseViewportOrderAndCapAtNine() {
        let targets = (0..<12).map { CommandNumberTarget.snip(uuid($0)) }
        let frames = Dictionary(uniqueKeysWithValues: targets.enumerated().map { index, target in
            (
                target,
                CGRect(x: 0, y: CGFloat(index) * 40, width: 200, height: 36)
            )
        })

        let visible = CommandNumberLayout.visibleTargets(
            ordered: targets,
            frames: frames,
            viewport: CGRect(x: 0, y: 80, width: 200, height: 400)
        )

        XCTAssertEqual(
            visible,
            (2..<11).map { CommandNumberTarget.snip(uuid($0)) }
        )
    }

    func testVisibleTargetsFallBackToListOrderWhenFramesAreMissing() {
        let targets = (0..<4).map { CommandNumberTarget.clipboardEntry(uuid($0)) }

        XCTAssertEqual(
            CommandNumberLayout.visibleTargets(
                ordered: targets,
                frames: [:],
                viewport: CGRect(x: 0, y: 0, width: 200, height: 400)
            ),
            targets
        )
    }

    func testNumbersAreOneBasedAndSkipHiddenOverlay() async {
        let picker = CommandNumberPicker(revealDelay: .milliseconds(20))
        let first = CommandNumberTarget.snip(uuid(0))
        let second = CommandNumberTarget.clipboardEntry(uuid(1))
        picker.setOrderedTargets([first, second])
        picker.setViewport(CGRect(x: 0, y: 0, width: 100, height: 100))
        picker.setRowFrame(first, frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        picker.setRowFrame(second, frame: CGRect(x: 0, y: 40, width: 100, height: 40))

        XCTAssertEqual(picker.target(forNumber: 2), second)
        XCTAssertNil(picker.displayedNumber(for: first))

        picker.handleCommand(isDown: true)
        XCTAssertFalse(picker.isRevealed)
        await waitForReveal(picker)

        XCTAssertTrue(picker.isRevealed)
        XCTAssertEqual(picker.displayedNumber(for: first), 1)
        XCTAssertEqual(picker.displayedNumber(for: second), 2)
    }

    func testOtherCommandKeysSuppressRevealUntilCommandReleases() async {
        // With no delay, a scheduled reveal runs on the main actor ahead of the yields below.
        let picker = CommandNumberPicker(revealDelay: .zero)
        let target = CommandNumberTarget.snip(uuid(0))
        picker.setOrderedTargets([target])
        picker.handleCommand(isDown: true)
        await waitForReveal(picker)
        XCTAssertTrue(picker.isRevealed)

        picker.noteNonDigitCommandKey()
        XCTAssertFalse(picker.isRevealed)

        picker.handleCommand(isDown: true)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(picker.isRevealed)

        picker.handleCommand(isDown: false)
        picker.handleCommand(isDown: true)
        await waitForReveal(picker)
        XCTAssertTrue(picker.isRevealed)
        XCTAssertEqual(picker.displayedNumber(for: target), 1)
    }

    func testCommandDigitPicksWhileTheShortcutIsEnabled() {
        XCTAssertEqual(
            CommandNumberKeyHandling.action(
                isEnabled: true,
                hasPureCommand: true,
                commandIsDown: true,
                number: 3
            ),
            .pick(3)
        )
        XCTAssertEqual(
            CommandNumberKeyHandling.action(
                isEnabled: false,
                hasPureCommand: true,
                commandIsDown: true,
                number: 3
            ),
            .ignore
        )
        XCTAssertEqual(
            CommandNumberKeyHandling.action(
                isEnabled: true,
                hasPureCommand: true,
                commandIsDown: true,
                number: nil
            ),
            .suppressReveal
        )
        XCTAssertEqual(
            CommandNumberKeyHandling.action(
                isEnabled: false,
                hasPureCommand: true,
                commandIsDown: true,
                number: nil
            ),
            .ignore
        )
    }

    func testNumberKeysResolveFromKeyCodeWhenCharactersAreEmpty() {
        XCTAssertEqual(CommandNumberLayout.number(fromCharacters: "4"), 4)
        XCTAssertNil(CommandNumberLayout.number(fromCharacters: ""))
        XCTAssertEqual(CommandNumberLayout.number(fromKeyCode: UInt16(kVK_ANSI_1)), 1)
        XCTAssertEqual(CommandNumberLayout.number(fromKeyCode: UInt16(kVK_ANSI_Keypad9)), 9)
        XCTAssertNil(CommandNumberLayout.number(fromKeyCode: UInt16(kVK_ANSI_A)))
    }

    func testPickInvokesTheHandlerForAVisibleTarget() {
        let picker = CommandNumberPicker(revealDelay: .zero)
        let target = CommandNumberTarget.snip(uuid(0))
        var picked: CommandNumberTarget?
        picker.startMonitoring { picked = $0 }
        picker.setOrderedTargets([target])
        picker.pickDisplayedNumber(1)
        XCTAssertEqual(picked, target)
        picker.stopMonitoring()
    }

    // Two targets with only the second in view: if its frame were lost, the list-order fallback
    // would number the off-screen first target instead.
    func testDepartingOwnerCannotClearTheActiveOwnerFrame() {
        let picker = CommandNumberPicker()
        let departingOwner = CommandNumberOwner()
        let activeOwner = CommandNumberOwner()
        frameOffscreenThenVisibleTargets(in: picker, owner: departingOwner)
        frameOffscreenThenVisibleTargets(in: picker, owner: activeOwner)

        picker.setRowFrame(visibleTarget, frame: nil, owner: departingOwner)

        XCTAssertEqual(picker.target(forNumber: 1), visibleTarget)
    }

    func testReleasingDepartingOwnerPreservesTheActiveOwnerFrame() {
        let picker = CommandNumberPicker()
        let departingOwner = CommandNumberOwner()
        let activeOwner = CommandNumberOwner()
        frameOffscreenThenVisibleTargets(in: picker, owner: departingOwner)
        frameOffscreenThenVisibleTargets(in: picker, owner: activeOwner)

        picker.releaseOwner(departingOwner)
        picker.setRowFrame(visibleTarget, frame: nil, owner: departingOwner)

        XCTAssertEqual(picker.target(forNumber: 1), visibleTarget)
    }

    func testReleasedOwnerCanBecomeActiveAgainWithItsCachedFrame() {
        let picker = CommandNumberPicker()
        let owner = CommandNumberOwner()
        frameOffscreenThenVisibleTargets(in: picker, owner: owner)
        picker.releaseOwner(owner)

        XCTAssertNil(picker.target(forNumber: 1))

        picker.setOrderedTargets([offscreenTarget, visibleTarget], owner: owner)

        XCTAssertEqual(picker.target(forNumber: 1), visibleTarget)
    }

    private var offscreenTarget: CommandNumberTarget { .snip(uuid(1)) }
    private var visibleTarget: CommandNumberTarget { .snip(uuid(0)) }

    private func frameOffscreenThenVisibleTargets(
        in picker: CommandNumberPicker,
        owner: CommandNumberOwner
    ) {
        picker.setOrderedTargets([offscreenTarget, visibleTarget], owner: owner)
        picker.setViewport(CGRect(x: 0, y: 0, width: 100, height: 100), owner: owner)
        picker.setRowFrame(offscreenTarget, frame: CGRect(x: 0, y: 500, width: 100, height: 40), owner: owner)
        picker.setRowFrame(visibleTarget, frame: CGRect(x: 0, y: 0, width: 100, height: 40), owner: owner)
    }

    private func waitForReveal(_ picker: CommandNumberPicker) async {
        let revealed = expectation(description: "Command-number overlay revealed")
        let subscription = picker.$isRevealed.filter { $0 }.prefix(1).sink { _ in
            revealed.fulfill()
        }
        defer { subscription.cancel() }
        await fulfillment(of: [revealed], timeout: 2)
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
