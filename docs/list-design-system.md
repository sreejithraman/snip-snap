# List identity

Each list has a name, an SF Symbol, and an optional light/dark color pair. The shared palette lives in `SnipSnapCore/SnipListColor.swift`, with native rendering in `Shared/SnipListAppearance.swift`; it supplies the picker and color roles to both apps. Platform views own their layout and control sizes.

Use the accent on list icons, a soft tint behind the selected list, and the enabled composer send button’s native Liquid Glass material. The send capsule stays inside the input. Keep names, snip text, errors, and disabled controls in their existing roles. Color adds identity; the name, icon, and selected state must still work without it. Native glass supplies its own edges and material, as described in ADR 0008.

The palette includes neutral, red, orange, yellow, green, blue, indigo, and violet. Each accent has a saturated light-mode value and a brighter, saturated dark-mode value. Glass controls apply a shared 80% tint strength to the saved color; the stored hex pair stays at full strength. The picker uses native tinted Liquid Glass buttons with a selected checkmark and names each choice for VoiceOver. Its targets are at least 44 points on both platforms. On Mac, swatches use a plain button with a tinted `glassEffect`; the glass button style does not show the swatch tint in the list sheet. Each composer keeps Send in a separate overlay and glass container, inside the input’s visible bounds. Neutral Send arrows use the opposite of the view’s light or dark appearance; colored arrows use white with 12% of the list color.

`SnipList.color` stores both sRGB values as one validated `#RRGGBB` pair. Neutral is `nil`. Names such as Violet belong to the picker; saving a preset copies its hex values. Later palette changes therefore do not change saved lists. Valid custom pairs survive edits, backups, and sync, and display as Custom in the picker. The current picker offers presets only.

SwiftData schema 6 stores `lightHex` and `darkHex`. Its migration converts schema 5 IDs to pairs and clears the retired nullable ID column. Older lists default to neutral. JSON backups store a `color` object with `light` and `dark`, or null; the decoder also accepts the earlier ID format.

CloudKit stores the pair as JSON bytes in one encrypted List `color` field. Name, icon, and color merge separately; the two hex values merge together. Conflicting pairs use the existing recovered-list flow. An explicit null clears the color on other devices.

Before TestFlight or release, deploy the additive `color` field from `CloudKit/SnipSnap.ckdb` through the normal schema release process. The production schema has not changed. Local tests use the fake transport.

## Review

Use `scripts/run.sh` for the Mac Dev app. Use `scripts/run.sh ios-simulator SIMULATOR_ID` for the iOS Dev app on a booted simulator. Both claim this worktree's Dev slot. The simulator app uses its own bundle ID and local store, with iCloud and App Groups disabled.

Check creation, editing, cancel, switching lists, reopening, light and dark appearance, large text, and VoiceOver selection. Keep screenshots of the picker and selected lists on both platforms.
