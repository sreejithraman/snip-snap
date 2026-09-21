# List identity

Each list has a name, an SF Symbol, and an optional color preset. The shared palette lives in `SnipSnapCore/SnipListColor.swift`, with native rendering in `Shared/SnipListAppearance.swift`; it supplies the picker and color roles to both apps. Platform views own their layout and control sizes.

Use the accent on list icons, a soft tint behind the selected list, and the enabled composer send button’s native Liquid Glass material. The send capsule stays inside the input. Keep names, snip text, errors, and disabled controls in their existing roles. Color adds identity; the name, icon, and selected state must still work without it. Native glass supplies its own edges and material, as described in ADR 0008.

The palette includes neutral, red, orange, yellow, green, teal, blue, indigo, violet, pink, clay, and slate. The spectral accents are saturated, while clay and slate provide restrained warm and cool alternatives. Every colored preset has a separately chosen light- and dark-mode value. Glass controls apply a shared 80% tint strength to the resolved display color. The shared picker uses plain buttons with a tinted `glassEffect` on both platforms. A larger circular glass overlay marks selection with a slight tint from the current theme, independent of the swatch color. Reduce Transparency and Increase Contrast use solid swatches with a primary-color selection ring. The picker names each choice for VoiceOver and exposes its selected state. Its targets are at least 44 points, with gaps between the glass surfaces. Each composer keeps Send in a separate overlay and glass container, inside the input’s visible bounds. Neutral Send arrows use the opposite of the view’s light or dark appearance; colored arrows use white with 12% of the list color.

`SnipList.color` stores a stable `SnipListColorPreset` identity such as `red` or `violet`. Neutral is `nil`. Each preset resolves to its current adaptive sRGB values when rendered, so palette improvements automatically reach saved lists. The app does not store or offer custom colors.

SwiftData schema 9 stores the preset's raw value in optional `colorPresetID`. Frozen historical schemas retain their old `colorID`, `lightHex`, and `darkHex` fields only so existing stores remain openable. Migration drops all of those values without translating them, so existing colors become neutral while the rest of each list survives. JSON backups store `colorPreset` as a string. Missing and unknown preset IDs become neutral.

CloudKit stores the preset as JSON bytes in one encrypted List `colorPreset` field. The old encrypted `color` pair is ignored and removed on the next list write. Name, icon, and color merge separately. Conflicting preset edits use the existing recovered-list flow. An explicit null clears the color on other devices.

Before TestFlight or release, deploy `colorPreset` additively through the normal schema release process: export the existing Development schema, merge in the field from `CloudKit/SnipSnap.ckdb`, validate, import, and then promote. The checked-in file is the clean current-runtime baseline, so it intentionally omits the retired field and must not be used as a destructive diff against an existing container. The production schema has not changed. Local tests use the fake transport.

## Review

Use `scripts/run.sh` for the Mac Dev app. Use `scripts/run.sh ios-simulator SIMULATOR_ID` for the iOS Dev app on a booted simulator. Both claim this worktree's Dev slot. The simulator app uses its own bundle ID and local store, with iCloud and App Groups disabled.

Check creation, editing, cancel, switching lists, reopening, light and dark appearance, large text, and VoiceOver selection. Keep screenshots of the picker and selected lists on both platforms.
