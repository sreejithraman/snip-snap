# Safari-style list selector research

Research date: 8 September 2026. This note distinguishes public API facts, reports from other developers, and proposed app behavior. No third-party code or assets were copied.

## Public API facts

- `UIGlassEffect` is a public `UIVisualEffect`. Its documented controls are its style, `tintColor`, and `isInteractive`. Its styles are `.regular` and `.clear`. The documented surface has no blur-radius or refraction-strength control, and does not document a `UIClearGlassEffect` class. [UIGlassEffect](https://developer.apple.com/documentation/uikit/uiglasseffect), [styles](https://developer.apple.com/documentation/uikit/uiglasseffect/style)
- SwiftUI exposes `Glass.clear`. “Clear” is a material choice, not a promise that backdrop text remains pixel-sharp. [Glass.clear](https://developer.apple.com/documentation/swiftui/glass/clear)
- Apple says regular glass adapts to preserve legibility; clear glass stays more transparent and needs care with contrast. Some controls become glass only during touch. Apple advises against stacking glass surfaces. A subtle plain track with one glass selection surface fits that advice better than two glass layers. Native glass responds to Reduce Transparency, Increase Contrast, and Reduce Motion. [Meet Liquid Glass, WWDC25](https://developer.apple.com/videos/play/wwdc2025/219/)
- SwiftUI's normal glass composition puts material below its content and highlights above it. Labels placed inside the glass stay legible; labels placed behind a separate glass overlay become sampled backdrop content. Those are different rendering cases. Glass effect containers let nearby glass share sampling regions. [Apple's WWDC25 recap](https://developer.apple.com/videos/play/meet-with-apple/201/?time=2351)

## Developer forums: evidence of a matching problem

The Apple Developer Forums post **“Liquid Glass clear variant isn't clear”** includes a minimal horizontal scrolling picker, a capsule overlay, and `.glassEffect(.clear)`. Its author reports blur across the center and asks how to reproduce Camera's clear selector. A separate UIKit post, **“iOS 26 Liquid Glass - Without any Blur - Possible?”**, reports the same result with `UIVisualEffectView(effect: UIGlassEffect(style: .clear))` and cites Camera and the text magnifier. These are developers' observations, not an Apple guarantee or an Apple statement that a workaround exists. The search index returned the posts through tag pages; those pages can move as new posts arrive. [SwiftUI report](https://developer.apple.com/forums/tags/design?page=5), [UIKit report](https://developer.apple.com/forums/tags/uikit?page=10)

This supports testing blur in an isolated sample before blaming the app hierarchy. It does not establish Safari's implementation.

## First-party blog and open-source examples

- Majid Jabrayilov's own sample compares regular, clear, tinted, and interactive SwiftUI glass. It demonstrates the public styles; it does not show a blur-free backdrop lens. [Glassifying custom SwiftUI views](https://swiftwithmajid.com/2025/07/16/glassifying-custom-swiftui-views/)
- Ryan Ashcraft's FabBar post explains using `UISegmentedControl` for the native touch-down glass effect. Its repository warns that it manipulates internal UIKit view hierarchy. That makes it a useful experiment to study, but a poor dependency for this selector. [Author's post](https://ryanwesley.com/introducing-fabbar/), [repository](https://github.com/ryanashcraft/FabBar), [public wrapper source](https://raw.githubusercontent.com/ryanashcraft/FabBar/main/Sources/FabBar/FabBar.swift)
- FabBar uses the MIT license, copyright Ryan Ashcraft, 2025. Redistribution or substantial copying requires keeping its copyright and permission notice. No code was copied here. [License](https://raw.githubusercontent.com/ryanashcraft/FabBar/main/LICENSE)
- UnionTabView describes invisible `UISegmentedControl` segments with custom SwiftUI labels above them. Its README calls the license MIT. This shows a second way to reuse native selection interaction, but does not establish content-sized scrolling, over-pull creation, or Safari's lens rendering. Do not adopt code based only on the README license claim without checking its complete license text. [UnionTabView](https://github.com/unionst/union-tab-view)
- Sascha Gordner's expandable segmented-control sample renders icon-and-label content into images because native segments accept an image or text. The author calls it a demo rather than production code. No license was verified, so do not copy it. [Sample](https://gist.github.com/saschagordner/a33b5efc9f1179bc1bb3713b8b95bbf2)

## What remains unknown

No source above proves which classes, material settings, shaders, or layers Safari uses for its tab-group selector. Claims that Safari uses a private clear-glass variant or a particular lens class remain assumptions. Native public clear glass can be the first rendering test, but exact Safari parity is not a documented API promise.

## Prototype and implementation decision

1. Compare the same text strip under regular and clear glass, then compare with text as glass foreground content. Keep shape, size, background, scale, and tint fixed. Test at rest and while dragging, in light and dark mode. Check Reduce Transparency and Increase Contrast before diagnosing blur.
2. Avoid blur modifiers, raster snapshots, nested glass, and private hierarchy changes in the first sample. They can hide the cause of a mismatch.
3. If native clear still softens backdrop labels, record that finding. Test a synchronized foreground copy of the labels masked only to the capsule's inset center. Leave the edge labels behind native glass. This keeps native glass intact and adds no shader dependency. Disable hit testing and accessibility on the duplicate. Check for blurred duplicate halos and alignment during drag; a foreground copy alone does not remove the blurred copy beneath it. This is a proposed composition, not a claim about Safari.
4. Keep rendering separate from selection state. Center variable-width list items; use one selected ID and a transient over-pull state. The plus must stay outside the data model and normal content width. Commit creation once on release, then reuse the existing New List sheet and restore the saved selected ID on cancel.
5. Expose list choice and New List through accessibility actions as well as drag. Disable spring and elastic motion under Reduce Motion. Verify threshold release, below-threshold return, cancellation, deletion of the active list, and sheet creation without changing saved list data.

The final five points are design recommendations for this app. The parent implementation must record the prototype evidence and actual test results separately.

## Masking limits

Apple permits a mask directly on `UIVisualEffectView` or its `contentView`. The docs warn that masking a superview can make the effect fail and throw an exception. They also warn that alpha below 1 on the effect view or its ancestors can spoil rendering. UIKit copies a direct effect mask; after a size change, reset the mask on the view. [UIVisualEffectView](https://developer.apple.com/documentation/uikit/uivisualeffectview/)

Thus a native capsule with only the foreground label copy masked is the simpler first experiment. If it leaves a blurred shadow around letters, a direct UIKit effect mask that keeps the glass rim and opens its center is a public alternative to test. It may also remove center tint or highlights and create a visible seam. Do not assume SwiftUI `.mask` after `.glassEffect` maps to the supported UIKit placement; verify the actual appearance. Do not mask or fade the whole selector's ancestor merely to fade its labels. Fade the label strip alone.

## Initial rendering study (superseded below)

The minimal iOS 26.5 Simulator prototype showed center blur and reflected text above and below the label with native clear glass. Placing a sharp label over that backdrop left the reflected copies visible. Splitting the label strip into complementary regions removed them: only the rim samples text behind glass; the inset center draws sharp text above glass. The glass itself stays intact. The prototype screenshots are `safari-glass-prototype.png` and `safari-glass-proof.png` in the task's local evidence directory.

Integration exposed a second cause of blur: the composer's shared `GlassEffectContainer` placed the selector glass above its foreground labels. Moving the selector outside that container restored the prototype result. The track is a plain low-opacity capsule. Edge fading applies to the labels, not the glass. This is an app-specific public-API composition, not a claim about Safari's layers.

The selector uses content-sized label widths, a direct drag gesture, nearest-center snapping, and a 72-point pull threshold measured before resistance. The plus has a transient position beyond the last label; it adds no resting item. A committed release emits one selection event through the app's haptic service and opens the existing creation sheet after the snap. The model never selects the plus. Cancel therefore retains the previous list, while a successful save uses the model's existing new-list selection.

## Checks completed

- Built and ran through `scripts/run.sh ios-simulator` in an isolated Dev slot.
- Passed all 95 iOS model, haptic, and selector geometry tests.
- Passed UI tests for creating and switching lists, choosing an icon, short-pull return, committed-pull creation, cancellation, repeat pulls, and drag selection.
- Built and installed the signed Dev app through `scripts/run.sh ios-device`. Initial launch required the phone to be unlocked.
- No dependency, asset, data model, or persistence format changed. The desktop list bar and iPad sidebar retain their existing behavior.
- Passed focused UI checks with Reduce Motion enabled: repeated pull creation and cancel, deletion that moves snips to Inbox, many content-sized lists and long names, selected-list actions, and the quick composer.
- The existing edit test used a stale label without an ellipsis. After updating its query and using a tap on the selected list, it passed icon, name, and color persistence checks.
- A broader snip-context-menu test run stalled waiting for system animation completion and was stopped. It is not counted as passing.
- Manually verified pull-to-create and neighbor taps in a separate local test library. Captured light, dark, largest Dynamic Type with Increase Contrast, and Reduce Transparency states. The selected text remained sharp; the solid fallback kept its outline and list color. Restored the tested Simulator settings afterward.
- The phone remained locked on the launch retry. Installation succeeded, but physical-device appearance and tactile quality remain unverified. Simulator tests establish haptic event requests, not their physical feel.

## Tint fade

The selection glass now interpolates its resolved color channels over 200 ms with ease-in-out timing, or 120 ms with Reduce Motion. SwiftUI can retarget the fade from its current value when the user changes direction. The same color interpolation applies to the solid fallback outline. A Simulator recording of taps and a drag showed intermediate colors across successive frames, including blue-to-green and green-to-blue transitions. The updated signed Dev build installed on the phone; launch still required unlocking it.

## Sharp refraction after the Safari reference

The user's crossing screenshot exposed a flaw in the split-mask approach: its straight inset boundary cut through a letter. The earlier checks at rest did not catch this. The final selector removes both complementary masks and the backdrop label copy.

A second isolated prototype tested one foreground label with SwiftUI’s public `distortionEffect` and an original Metal function. The center samples the text unchanged. Near the curved capsule rim, the shader moves one sample inward by at most eight points. It uses no blur kernel. Native clear glass remains below the labels for the resting capsule, tint, and highlights. This approximates the supplied reference; it does not establish Safari’s shader or internals. [Apple’s distortion effect API](https://developer.apple.com/documentation/swiftui/visualeffect/distortioneffect(_:maxsampleoffset:isenabled:))

The shader bounds animate with the capsule width. Reduce Transparency disables the refraction and keeps the solid fallback. Reduce Motion retains direct finger tracking and removes the snap spring; the short tint fade remains. The viewport edge fade affects labels only.

The prototype showed a sharp center and curved stretching of the final letter. A recording of the integrated selector showed the same curved stretching as text and icons crossed the rim, without the former straight inset cutoff or diffuse backdrop text. The new source requires Apple’s optional Metal compiler (`xcodebuild -downloadComponent MetalToolchain`); the build guide and iOS CI jobs now install it. No third-party shader code or dependency was added.

The final build passed the existing pull-threshold/cancel/create and many-lists/menu UI tests, plus the tracked-input and iOS-target policy checks. It installed as Dev 6 on the iPhone; the locked phone prevented launch, so physical appearance and haptics remain unverified.

## Colored labels and plus reveal

Each list label now shares its icon’s accent color. During overscroll, the plus fades in from beyond the trailing edge and follows an ease-out path toward its pull position. A committed release uses the existing 300 ms spring to center it before opening New List. Short pulls reverse the reveal. Reduce Motion omits the added edge travel and snap spring. This change affects the bottom selector only.

Verified neighbor taps, short-pull return, committed-pull opening, and cancellation in Simulator. The existing repeated pull/cancel/create UI test passed. The updated Dev 6 app installed on the phone, which remained locked at launch.

## Tab title motion during swipes

The strip previously started its spring when the drag changed from zero, and derived the label position from the selected list plus a live drag offset. That allowed animation at touch-down and made the drag position depend on the selection changing at release.

The gesture now stores its absolute strip position and updates without animation. The strip applies the snap only after the gesture ends. List selection no longer runs inside a broad animation transaction. The refraction shader, label colors, and plus reveal are unchanged.

A frame-by-frame check then caught a separate fault: the title and symbol changed their spacing during a snap, including outside the refracting rim. A drawing group did not fix it. Disabling implicit child animation fixed the spacing but also removed the snap. The final `ListLabelPosition` interpolates one outer x position while disabling animation within the label. Recorded forward and reverse swipes keep the icon and title together. The native rim still bends them where they cross its edge.

The rendering issue needs a moving-frame check; geometry and action tests alone did not catch it. The local evidence includes before/after recordings and moving-frame strips. The temporary drawing group was removed.

The final tab create/switch and repeated pull/cancel/create UI tests passed. The final Dev 6 build installed on the iPhone; the phone was locked at its launch attempt.

## Sticky edge before creation

The plus now enters from outside the trailing edge and stays close to it through the pull. After its initial reveal, it yields only 12 points toward the center. A committed release uses the existing snap spring to center it. The commit threshold is now 96 points of finger travel, up from 72, and the strip follows at 35% of excess travel rather than 60%. No timer or extra haptic was added. Reduce Motion uses a fixed edge position with a fade and an instant committed move.

The updated UI test checks that an 80-point pull returns without creating a list or emitting a haptic, while a 110-point pull commits. Geometry tests and the repeated pull/cancel/create UI test passed. Manual pulls confirmed return, committed snap, sheet opening, and cancellation.

The plus fade now uses the same normalized resisted travel as its position. One value drives both the 56-point entry and the final 12-point yield. This preserves the motion path and threshold while making opacity follow the same curve, including when the pull reverses. The build passed; recorded manual pulls verified return and committed sheet opening.
