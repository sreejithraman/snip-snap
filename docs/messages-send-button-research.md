# Messages send button research

Date: 2026-09-02

This note checks Apple's public guidance for the compact send button shown in Messages on current iOS releases. Apple documentation and Apple sessions are the sources for platform claims. The screenshot check and repo check are marked as local findings.

## Short answer

Apple does not publish a Messages send-button size, padding value, or width-to-height ratio. Messages shows a short horizontal capsule, but that exact control is not a public component with a documented size.

The closest public SwiftUI setup is a prominent glass button with a capsule border and fitted sizing. Snip Snap does not use that setup on iOS because the target Messages control is solid. Instead, it uses a solid capsule whose height follows the control row and whose width extends that height by one icon width. Its hit region remains at least 44 by 44 points. [Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/), [`ButtonSizing.fitted`](https://developer.apple.com/documentation/swiftui/buttonsizing/fitted), [Buttons — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/buttons)

iOS 27 does not add a documented compact-send-button size. Apple says apps get the revised Liquid Glass look on the 2027 operating systems without code changes. The capsule and glass button APIs came with the iOS 26 design. [What’s new in SwiftUI](https://developer.apple.com/videos/play/wwdc2026/269/)

## What Apple publishes

Apple says bordered buttons use a capsule by default in the new design. SwiftUI also lets an app request a capsule with `buttonBorderShape(.capsule)` and apply the prominent Liquid Glass style with `buttonStyle(.glassProminent)`. Apple gives no point size or aspect ratio for this combination. [Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/), [`ButtonBorderShape.capsule`](https://developer.apple.com/documentation/swiftui/buttonbordershape/capsule), [`glassProminent`](https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glassprominent)

`buttonSizing(.fitted)` asks a button to size its main axis to its inner content and compress when needed. This is the public API that most directly prevents a button from taking needless width. It does not set an exact width or ratio. [`ButtonSizing.fitted`](https://developer.apple.com/documentation/swiftui/buttonsizing/fitted), [`buttonSizing(_:)`](https://developer.apple.com/documentation/swiftui/view/buttonsizing(_:))

`controlSize(.small)` makes a control proportionally smaller for a space-limited view, while `.mini` asks for the smallest control size. Apple does not publish iOS point sizes for these SwiftUI values, and neither value is named as the Messages send-button setting. [`ControlSize.small`](https://developer.apple.com/documentation/swiftui/controlsize/small), [`controlSize(_:)`](https://developer.apple.com/documentation/swiftui/view/controlsize(_:))

Apple's button guidance calls for a hit region of at least 44 by 44 points. That is a target-size rule, not a rule that every visible button background must fill a 44-point square. The visible capsule can sit inside a larger clear hit region. [Buttons — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/buttons)

Apple's current SwiftUI lab guidance says to use the glass button styles for buttons, then pair them with `buttonBorderShape`. It warns against placing a raw glass effect behind a button. It gives no send-button dimensions. [SwiftUI Group Lab](https://developer.apple.com/videos/play/wwdc2026/8120/)

## What the Messages screenshot shows

Local observation: the supplied screenshot shows a visible send platter that is about 1.3 to 1.4 times as wide as it is tall. Its exact point size cannot be recovered from this crop because the image may have been resized. This is useful as a visual target, but it is not an Apple specification.

The screenshot also shows that the visible platter does not fill the composer height. It sits inside a larger area with clear space above and below. This matches the HIG distinction between a visible shape and its larger hit region.

Messages appears to use a tuned first-party control. Apple does not document its inner padding, control size, or implementation, so a measured ratio should not become a shared platform rule.

## Community findings

No high-signal third-party source publishes a verified iOS 26 or iOS 27 Messages send-button frame. Searches across public SwiftUI discussions, chat SDK guides, and open-source chat composers found many visual copies, but no one tied an exact width, height, padding, or ratio to runtime inspection of the current Messages app.

Stream's UIKit chat SDK has a guide devoted to making its composer look like iMessage. It moves the send button into the text-input container, bottom-aligns it, gives the input an 18-point corner radius, and makes the attachment control 30 by 30 points. It does not claim or set an iMessage send-button size. This supports the layout pattern in the screenshot, but not an exact send-button measurement. [Stream iMessage-style composer guide](https://getstream.io/chat/docs/sdk/ios/uikit/components/message-composer/)

An open-source SwiftUI chat view in Foundation Models Framework Lab uses an icon-only `glassProminent` send button with `controlSize(.large)` and a separate minimum touch-target frame. It does not add label padding or a fixed aspect ratio. This is a concrete public implementation of the native approach, not evidence of Messages' own values. [Foundation Models Framework Lab `ChatInputView`](https://github.com/rudrankriyam/Foundation-Models-Framework-Lab/blob/main/Foundation%20Lab/Views/Components/ChatInputView.swift)

Other recent public chat examples still use fixed circular buttons, such as a 46-point circle in Companion's Liquid Glass chat demo and a 46-point circle in its queued-message composer. These implementations show that community code has not settled on the new Messages capsule as a standard SwiftUI preset. [Companion `GlassChatDemoView`](https://github.com/The-Vibe-Company/companion/blob/main/apps/ios/Companion/Screens/GlassChatDemoView.swift), [Companion `CompanionQueuedMessagesDemoView`](https://github.com/The-Vibe-Company/companion/blob/main/apps/ios/Companion/Screens/CompanionQueuedMessagesDemoView.swift)

A SwiftUI community thread asking how to reproduce Apple's iOS 26 bottom glass buttons reached the same API set: a native glass button style, a control size, a capsule shape, and `buttonSizing`. The examples use `.flexible` for a full-width action, which is the opposite of a compact send button. Apple's docs confirm that `.flexible` fills available space while `.fitted` follows the inner content. [SwiftUI community discussion](https://www.reddit.com/r/SwiftUI/comments/1rck7zw/ios_26_bottom_button/), [`ButtonSizing`](https://developer.apple.com/documentation/swiftui/buttonsizing)

SwiftUI Garden documented a system glass-button sizing bug where a circle widened into a capsule while pressed, then reported it fixed in iOS 26.1 beta 2. The sample uses a 32-by-32-point label inside a native glass button. This is useful evidence that the rendered platter can change with the system release and that hard-coding around one rendering can age poorly; it does not measure Messages. [SwiftUI Garden glass-button report](https://swiftui-garden.com/Misc/iOS-26/Standalone-Glass-Buttons-widen-to-a-capsule-when-tapped)

The public MessageUI API exposes `MFMessageComposeViewController`, a complete standard compose screen. It does not expose the Messages send control as a reusable view or publish its layout values. A historical reverse-engineering reference found private ChatKit entry views such as `CKMessageEntryRichTextView` inside Messages, but that inspection predates iOS 26 and cannot prove the current class tree. The safe conclusion is only that no current public send-button component exists. [`MFMessageComposeViewController`](https://developer.apple.com/documentation/messageui/mfmessagecomposeviewcontroller), [historical iOS app reverse-engineering reference](https://algorithm-master.github.io/Books/iOSAppReverseEngineering.pdf)

### What the community evidence changes

- It gives no sound basis for a fixed shared ratio.
- It supports placing the send action inside the input container and bottom-aligning it.
- It supports native button styling with no extra label padding.
- It supports a separate touch-target frame around the visible control.
- It favors `.buttonSizing(.fitted)` for this compact action. `.buttonSizing(.flexible)` is for controls meant to stretch.
- It does not identify `.controlSize(.small)` as the Messages choice. A recent native example uses `.large`; other examples set their own 44- or 46-point frames.

## Snip Snap decision

Keep the Mac button native. Let its prominent glass style and capsule border choose the control height, with only the small icon padding needed to match the surrounding field:

```swift
.buttonStyle(.glassProminent)
.buttonBorderShape(.capsule)
```

Use a solid capsule for the iOS composer. Compute it from scaled inputs rather than a fixed aspect ratio:

```text
visible height = control height - (edge inset × 2)
visible width = visible height + icon width
```

Use the same scaled edge inset on the top, bottom, and right. Keep the arrow centered and the hit region at least 44 points high. Base the button on the single-line control row so a multiline draft does not stretch it.

iOS 27 adds no public Messages send-button sizing rule, so keep this geometry unless testing on that Simulator shows a real layout problem.
