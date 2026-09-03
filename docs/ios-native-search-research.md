# Native top search on iOS 26

Date: September 3, 2026

This note checks Apple’s current design rules, SwiftUI docs, sessions, and the
iOS 26.5 SDK for a search button in Snip Snap’s top bar. Apple sources are the
only sources for platform claims.

## Short answer

Apple supports search in an iPhone top bar. The native inactive form is a
search button. A tap lets the system animate it into a search field, either
above the keyboard or at the top when the bottom has no room. Apple says top
search fits a view that has no bottom bar or must leave the bottom clear.
[Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields)

The most native SwiftUI form is:

```swift
.searchable(
    text: $searchText,
    isPresented: $isSearchPresented,
    prompt: "Search Snips"
)
.searchToolbarBehavior(.minimize)
.toolbar {
    DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
}
```

Keep `searchable` attached for the full life of the screen. Change only the
`isPresented` binding when code must open or close search. SwiftUI then owns
focus, the keyboard, the field, its Liquid Glass surface, and the transition.
[Managing search interface activation](https://developer.apple.com/documentation/swiftui/managing-search-interface-activation),
[`searchable(text:isPresented:placement:prompt:)`](https://developer.apple.com/documentation/swiftui/view/searchable%28text%3Aispresented%3Aplacement%3Aprompt%3A%29),
[Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)

There is one firm limit: the system search toolbar item does not support
`topBarLeading`. Apple documents `bottomBar` on iPhone, `topBarTrailing`, and
`automatic` as its supported placements. An exact leading-edge search button
therefore needs an app-owned button. Its action can still open an always
attached native search interface, but the trigger and its link to the field
are no longer wholly system-owned.
[`ToolbarDefaultItemKind.search`](https://developer.apple.com/documentation/swiftui/toolbardefaultitemkind/search),
[`DefaultToolbarItem`](https://developer.apple.com/documentation/swiftui/defaulttoolbaritem)

## Recommendation for Snip Snap

Use the system search item at `topBarTrailing`, ordered before Filter and More.
This is the only public SwiftUI path that gives the system full control of the
inactive button, expansion, focus, keyboard, toolbar changes, and Liquid Glass.
It also removes the first-tap placement change.

If screen-leading search is a fixed product rule, keep the custom leading
button. Treat this as a compromise: Apple does not offer a system search item
at that placement, so the button-to-field transition cannot stay wholly
system-owned.

Apple’s top-search example groups Search and More on the trailing edge. Its
toolbar guide reserves the far leading edge mainly for Back, Close, and
sidebar controls. This makes trailing search the stronger platform match even
though a top search entry point itself is valid.
[Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields),
[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)

## Decision for this change

Snip Snap keeps the product rule: Search stays on the leading edge, while
Filter and More stay on the trailing edge. The built-in search item and a
programmatically opened `searchable` field both fell back to the bottom in an
iOS 26.5 test. The app therefore uses a standard leading toolbar button and a
native `UISearchBar` in a top safe-area bar. The search bar supplies the
platform's field, clear control, text entry, focus, and keyboard. A standard
round glass button beside it closes search. The app owns that action, the
stable top placement, and the dimmed background.

This is less native than moving Search to the trailing edge, but it is the
smallest custom surface that meets both fixed placement rules. The app does
not copy a system search transition or try to force an unsupported default
toolbar placement.

## Why the first tap differs

The first tested implementation added `searchable` only after
`isSearchPresented` became true. That one update both created the search host
and asked it to present. On later taps, SwiftUI had already registered and laid
out the host, which matched the observed move from bottom on the first tap to
top on later taps.

Apple does not document this exact iOS 26.5 result, so the timing detail is an
inference from the local test. Apple does document the two facts behind the
fix:

- Its programmatic examples leave `searchable` attached and use the Boolean
  binding to activate it.
- Conditional branches give views distinct structural identities. Apple asks
  developers to preserve identity when one element changes state.

[Managing search interface activation](https://developer.apple.com/documentation/swiftui/managing-search-interface-activation),
[Demystify SwiftUI](https://developer.apple.com/videos/play/wwdc2021/10022/)

Changing the drawer display mode from `automatic` to `always` cannot fix this
life-cycle issue. It only controls whether scroll activity may hide a drawer
field.

## What each search API does

### `searchToolbarBehavior(.minimize)`

This iOS 26 API asks SwiftUI to prefer a button-like search control while
search is inactive. Apple uses it for search that is useful but not the main
part of the app. The system may also minimize search on its own based on the
device, space, and number of toolbar buttons.
[SearchToolbarBehavior](https://developer.apple.com/documentation/swiftui/searchtoolbarbehavior),
[Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)

### `DefaultToolbarItem(kind: .search, placement:)`

This moves the search item created by `searchable`; it does not create a
second search system. It is the native way to order search among other toolbar
items. Its supported top placement is trailing, not leading.
[`DefaultToolbarItem.init(kind:placement:)`](https://developer.apple.com/documentation/swiftui/defaulttoolbaritem/init%28kind%3Aplacement%3A%29),
[`ToolbarDefaultItemKind.search`](https://developer.apple.com/documentation/swiftui/toolbardefaultitemkind/search)

### `navigationBarDrawer(displayMode:)`

This is an inline field below the navigation title. `automatic` lets scrolling
hide it; `always` keeps it visible despite scrolling. It is not the iOS 26
toolbar button that expands into a field.
[`navigationBarDrawer(displayMode:)`](https://developer.apple.com/documentation/swiftui/searchfieldplacement/navigationbardrawer%28displaymode%3A%29)

### `searchPresentationToolbarBehavior`

The default iOS search presentation may hide toolbar content to focus the
search task. `avoidHidingContent` asks it not to do so. This API does not pick
the field’s top or bottom placement. Snip Snap should keep the automatic value
unless Filter or More must remain usable during an active search.
[`searchPresentationToolbarBehavior(_:)`](https://developer.apple.com/documentation/swiftui/view/searchpresentationtoolbarbehavior%28_%3A%29)

## Liquid Glass rule

Do not add `glassEffect` to a system search button or field. Standard toolbar
and search controls get their Liquid Glass look from the system. Snip Snap's
native `UISearchBar` uses that system look without an extra glass layer. Apple
asks apps to use standard controls where they fit and remove custom bar
backgrounds that interfere with the system's edge effect.
[Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/),
[Landmarks: Refining the system-provided glass effect in toolbars](https://developer.apple.com/documentation/swiftui/landmarks-refining-the-system-provided-glass-effect-in-toolbars)
