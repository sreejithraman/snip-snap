# Color options beyond rainbow and neutral

Research date: 2026-09-20

## Recommendation

Keep SnipSnap preset-first and expand the current palette from 8 to 12 choices:

1. Neutral
2. Red
3. Orange
4. Yellow
5. Green
6. **Teal**
7. Blue
8. Indigo
9. Violet
10. **Pink**
11. **Clay**
12. **Slate**

This adds two missing, commonly offered hue families (Teal and Pink) and two
lower-chroma identity colors (Clay and Slate). The latter are the important
answer to “more than rainbow”: they create a warmer and a cooler restrained
choice without turning the picker into a theme browser.

Teal and Pink should come first because they close the two largest gaps in the
current hue range. Their pairs should be chosen for the current picker rather
than maintained as a second historical palette:

| Preset | Light | Dark | Rationale |
| --- | --- | --- | --- |
| Teal | `#1C807A` | `#82FAF3` | Closes the large Green–Blue gap. |
| Red | `#E00000` | `#FF4040` | A true red without the old magenta cast, with separate values for light and dark appearances. |
| Pink | `#E0007F` | `#FF4FA3` | A brighter hot pink that stays distinct from Red and Violet through glass. |
| Clay | `#9A5A3C` | `#F0A17E` | A warm, muted brown/terracotta; deliberately not another spectral stop. |
| Slate | `#526678` | `#BBD1E5` | A cool, muted blue-gray; distinct from Neutral while still restrained. |

The current preset definitions are in
[`SnipListColor.swift`](../../Packages/SnipSnapLibrary/Sources/SnipSnapCore/SnipListColor.swift).
SnipSnap stores stable preset IDs, so expanding or tuning a preset recolors
existing lists consistently; that behavior is documented in the
[`list design system`](../list-design-system.md).

Do not add freeform color in the first expansion. Presets keep the picker fast,
make light/dark pairs curatable, and fit the current data and accessibility
model. Freeform color can remain a later feature if real demand appears.

## What other open-source products do

| Product | Choice model | Palette shape and naming | Light/dark and accessibility handling | Useful lesson for SnipSnap |
| --- | --- | --- | --- | --- |
| Firefox Multi-Account Containers | Presets only | 8 direct hue names: Blue, Turquoise, Green, Yellow, Orange, Red, Pink, Purple. It also offers a separate icon choice, so identity does not depend on color alone. ([palette and icons](https://github.com/mozilla/multi-account-containers/blob/6dbb0db0511fd4e0e9d1644920d1ed767f4aeb20/src/js/containerStyle.js#L5-L23), [radio-button picker](https://github.com/mozilla/multi-account-containers/blob/6dbb0db0511fd4e0e9d1644920d1ed767f4aeb20/src/js/popup.js#L1883-L1917)) | It asks Firefox for the browser-supported palette and falls back to its bundled values. The picker uses native radio inputs and labels. ([source](https://github.com/mozilla/multi-account-containers/blob/6dbb0db0511fd4e0e9d1644920d1ed767f4aeb20/src/js/containerStyle.js#L37-L75)) | Eight clear hues are enough for quick identity selection when name and icon remain primary. Pink and a cyan/teal family are standard gaps to fill. |
| Signal Desktop | Presets plus custom | 22 named choices: 12 solids and 10 gradients. Solid names mix hue and material terms (`crimson`, `burlap`, `forest`, `steel`, `taupe`); gradients use evocative names such as `ember`, `lagoon`, and `midnight`. ([choice list](https://github.com/signalapp/Signal-Desktop/blob/6aea489bd04f31f6070538ffdbcea9fcf492479d/ts/types/Colors.std.ts#L16-L39), [solid/gradient definitions](https://github.com/signalapp/Signal-Desktop/blob/6aea489bd04f31f6070538ffdbcea9fcf492479d/stylesheets/_variables.scss#L99-L168), [maps](https://github.com/signalapp/Signal-Desktop/blob/6aea489bd04f31f6070538ffdbcea9fcf492479d/stylesheets/_variables.scss#L238-L264)) | Preset buttons expose listbox/option roles, accessible labels, and selected state. A separate editor can create solid or gradient colors through hue and saturation controls. ([picker](https://github.com/signalapp/Signal-Desktop/blob/6aea489bd04f31f6070538ffdbcea9fcf492479d/ts/components/ChatColorPicker.dom.tsx#L183-L246), [custom editor](https://github.com/signalapp/Signal-Desktop/blob/6aea489bd04f31f6070538ffdbcea9fcf492479d/ts/components/CustomColorEditor.dom.tsx#L22-L170)) | Once basic hue coverage is complete, useful expansion comes from lower-chroma/material families, not ever-finer rainbow steps. Custom color is a separate, more complex flow with a preview. |
| Zulip | 24 presets plus freeform color | A 4×6 matrix deliberately mixes hue, lightness, and chroma: warm browns/reds/oranges, greens/yellows, mints/blues, and grays/pinks/purples. ([palette](https://github.com/zulip/zulip/blob/406a311c979fa8abb71f01b3b0c8b2136a774e75/web/src/stream_color.ts#L107-L112)) | Zulip clamps arbitrary input to an LCH lightness range and derives different light/dark renderings by mixing it into the active background. Its picker accepts either a swatch or a freeform color input. ([adaptive rendering](https://github.com/zulip/zulip/blob/406a311c979fa8abb71f01b3b0c8b2136a774e75/web/src/stream_color.ts#L32-L71), [preset/freeform interaction](https://github.com/zulip/zulip/blob/406a311c979fa8abb71f01b3b0c8b2136a774e75/web/src/color_picker_popover.ts#L136-L195)) | More choices can still scan well as a structured matrix. Arbitrary colors need normalization at render time; accepting any hex unchanged is not enough. |
| Zulip automatic assignment | Automatic presets with later editing | It keeps 24 assignment colors, shuffles them to avoid favoring the early entries, and consumes unused colors before recycling the set. ([assignment source](https://github.com/zulip/zulip/blob/406a311c979fa8abb71f01b3b0c8b2136a774e75/web/src/color_data.ts#L5-L70)) | If SnipSnap ever auto-colors new lists, prefer an unused-color strategy over random choice so adjacent lists remain distinguishable. |
| GNOME/libadwaita | System-selected adaptive accent presets | 9 semantic hue families: Blue, Teal, Green, Yellow, Orange, Red, Pink, Purple, Slate. Each family has separate background, foreground, light standalone, and dark standalone roles. ([official token table](https://github.com/GNOME/libadwaita/blob/main/doc/css-variables.md#accent-colors)) | The standalone accent is derived differently for light and dark appearance in Oklab, and the guidance says not to spread accent color over large surfaces or too many items. ([derivation and use guidance](https://github.com/GNOME/libadwaita/blob/main/doc/css-variables.md#accent-colors)) | A preset is a family of role-specific colors, not one hex reused everywhere. Teal, Pink, and Slate are strong additions because a mature adaptive system treats them as first-class accents. |

## Recurring design patterns

### 1. Small identity pickers cover hue families before adding shades

Firefox stops at 8 presets; libadwaita uses 9. Both include Pink and a
Teal/Turquoise family alongside the familiar red-to-purple spectrum.
SnipSnap's current 8 choices include Neutral but omit both of those hue gaps.
That makes Teal and Pink the least surprising first additions.

### 2. Larger palettes add tonal character, not just more hue stops

Signal adds Burlap, Taupe, and Steel alongside spectral colors, while Zulip's
matrix includes browns, warm grays, cool grays, and softened colors. These
options give a user “calm,” “warm,” or “professional” identities without
requiring a global theme. For SnipSnap, one warm muted choice (Clay) and one cool
muted choice (Slate) capture most of that benefit with little picker growth.

### 3. Presets remain the fast path even when freeform exists

Signal and Zulip both put swatches first and custom editing behind a separate
interaction. Custom input brings extra work: preview, validation, contrast
correction, persistence, reset behavior, and accessible naming. SnipSnap's
present preset-only picker is therefore a sound default, not a limitation that
must be removed while adding colors.

### 4. Appearance adaptation is a rendering problem

Zulip transforms a saved color for each background; libadwaita defines distinct
background, foreground, light, and dark roles. SnipSnap's presets define
separate light/dark values. New presets should keep individually chosen pairs
rather than compute a dark value by mechanically brightening RGB.

### 5. Color is supporting identity, not the identity itself

Firefox pairs color with an icon. SnipSnap already pairs it with the list name
and SF Symbol. Keep those visible and preserve a non-color selected indicator.
WCAG explicitly says that color must not be the only visual way to distinguish
information or state ([SC 1.4.1](https://www.w3.org/WAI/WCAG22/Understanding/use-of-color.html)).

## Product and implementation cautions

- **Keep names literal at this size.** `Teal`, `Pink`, `Clay`, and `Slate` are
  easier to localize and announce than a large set of poetic names. Signal's
  evocative names work because its 22 choices need shade-level distinction;
  Firefox and libadwaita use direct hue names for compact palettes.
- **Keep semantic status colors separate.** A red list is an identity choice,
  not an error; green is not success; yellow is not warning. Do not let list
  accents replace destructive, warning, or validation roles.
- **Validate every role, not just the swatch.** Check icon foreground, selected
  row tint, Send label, glass tint, focus/selection ring, disabled appearance,
  and both Reduce Transparency and Increase Contrast paths in light and dark
  mode. WCAG calls for 4.5:1 for normal text and 3:1 for meaningful control and
  state cues ([text contrast](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html),
  [non-text contrast](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html)).
- **Do not infer contrast from saturation.** The open Logseq accessibility
  report is a useful failure example: several accent-derived links, selection
  colors, and surfaces had very low measured contrast in dark mode, and the
  reporter notes that an accent must work against both the main surface and a
  dimmer sidebar ([official project issue](https://github.com/logseq/logseq/issues/11135)).
- **Avoid gradients for list identity for now.** Signal uses gradients on large
  chat bubbles with a live preview. SnipSnap generally uses accents in small
  icons, swatches, glass tints, and controls, where a gradient adds rendering
  complexity but little identification value.
- **Cap the main grid at 12.** Twelve is a tidy 4×3 set in the current picker.
  If more tonal variants are later justified, group them into an explicit
  second row/section or add a custom editor; do not silently grow an unstructured
  rainbow.

## Suggested rollout

1. Add Teal and Pink as first-class current presets. Treat obsolete stored
   preset IDs as unset rather than retaining or translating a second palette.
2. Add the independently chosen Clay and Slate pairs above. Their foreground
   contrast is 5.38:1 and 5.95:1 on white, and 8.09:1 and 10.70:1 on the dark
   app surface. Treat the libadwaita Slate family and Signal/Zulip muted colors
   as direction, not values to copy blindly.
3. Test the 12-choice grid at the narrowest macOS and iOS presentations, with
   VoiceOver labels and selected traits.
4. Run color-vision-deficiency simulations on the complete list row, not just
   isolated swatches. The list name, symbol, and selection treatment must still
   carry identity when two accents appear similar.
5. Leave custom colors out of the UI until there is evidence that 12 curated
   identities are insufficient.

## Scope and uncertainty

This is a source review and in-app implementation check, not a visual usability
study. The final palette and Red selection persistence were exercised in the
real macOS app and on the narrow iPhone 17e simulator. VoiceOver, color-vision-deficiency
simulation, and the other accessibility-mode checks above remain follow-up
validation. Repository sources were inspected at the pinned commits linked
above; libadwaita and W3C documentation links track their maintained first-party
pages.
