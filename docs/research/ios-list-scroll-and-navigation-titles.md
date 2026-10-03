# Preserving list position and native navigation titles on iOS

Research date: 2026-10-02

The code observations and reproduction below describe the original baseline. The implementation follow-up records the subsequently authorized fix.

## Recommendation

Keep each visited compact library page's native `List` and `NavigationStack` alive while switching between lists and Clipboard. Preserve stable `LibraryPage` identity, hide inactive pages, and disable their input and accessibility exposure. This is the smallest proposed change that preserves the native scroll position and associated navigation title behavior without reconstructing either. Limit this retention to the current library presentation, discard deleted pages, and measure its cost with many visited lists. This recommendation follows Apple's state-lifetime model; it is not a documented guarantee about Snip Snap's current failure. ([Demystify SwiftUI](https://developer.apple.com/videos/play/wwdc2021/10022/))

Keep one shared title policy: a named collection uses the native large title at the top and its compact title when scrolled. An inline-only policy is also supported, but is a separate visual design choice. A page returning to its original position should return to the title state appropriate to that position. Do not add a second app-rendered heading or toggle title modes from an arbitrary offset threshold to patch an unexplained transition. ([Title display modes](https://developer.apple.com/documentation/swiftui/navigationbaritem/titledisplaymode), [Apple navigation-bar sample](https://developer.apple.com/documentation/uikit/customizing-your-app-s-navigation-bar))

## Source-backed facts

- SwiftUI stores state for a view's identity lifetime. Removing a view ends that lifetime; a stable identifier alone does not preserve a subtree after removal. Recreating a view value during ordinary body updates is different from removing that identity. ([Demystify SwiftUI](https://developer.apple.com/videos/play/wwdc2021/10022/))
- Apple's navigation-bar sample describes a large title at the top of scrolling content that animates into the bar as scrolling begins. For iOS 26, Apple explains that large titles sit at the content scroll view's top and move with it beneath the bar. A large header at the top and a small header after scrolling are therefore expected states; two settled copies or the wrong state require reproduction. ([Navigation-bar sample](https://developer.apple.com/documentation/uikit/customizing-your-app-s-navigation-bar), [Build a UIKit app with the new design, navigation bars](https://developer.apple.com/videos/play/wwdc2025/284/?time=645))
- `List` includes an implicit scroll view. Apple says scroll-view modifiers can configure this implicit scroll view. This general guidance does not establish exact restoration behavior for every modifier or List configuration. ([Scroll views](https://developer.apple.com/documentation/swiftui/scroll-views))

## Current code observations

These observations describe the code inspected before implementation in this thread, not a runtime diagnosis.

- The iOS baseline is **26.0**, per [iOSShared.xcconfig](../../Config/iOSShared.xcconfig) and [ADR 0022](../adr/0022-require-ios-and-ipados-26.md). No iOS 17 compatibility layer is needed.
- The compact pager is a custom offset `ZStack`, **not** a page-style `TabView`. [CompactLibraryPageStack.swift](../../SnipSnapiOS/CompactLibraryPageStack.swift) renders only `frame.retainedPages`; each rendered page owns a `NavigationStack`.
- At rest, [ListPageMotion.swift](../../SnipSnapiOS/ListPageMotion.swift)'s `frame` returns `retainedPages: [selectedPage]`. Transition frames temporarily retain other pages. Returning to a previous page therefore rebuilds its subtree.
- [SnipCollectionViews.swift](../../SnipSnapiOS/SnipCollectionViews.swift) switches structurally between search, empty content, and `List`. Preserving the outer page alone does not preserve the List if another branch replaces it.
- [CollectionScreenPresentation.swift](../../SnipSnapiOS/CollectionScreenPresentation.swift) already centralizes title presentation: a nonempty title requests `.large`, while an empty title requests `.inline`. It also applies per-navigation-item UIKit title font and color attributes. This appearance bridge is a place to inspect if title glitches persist; reading it does not prove it causes them.
- [IOSClipboardView.swift](../../SnipSnapiOS/IOSClipboardView.swift) includes pin state in an explicit row ID. A later restoration design should distinguish semantic clipboard-entry identity from the row's presentation identity.

## Inferences and limits

Page removal is a strong explanation for lost scroll position: SwiftUI's lifetime rules and the pager's idle frame agree on the missing continuity. Confirm it with an A → B → A workflow and compare the same workflow after retention. The available evidence does **not** establish that every reported title glitch has the same cause.

The apparent header pattern may combine normal scroll-linked collapse with page recreation, search replacing List, editing changing title presentation, or a platform transition issue. Record which title copies appear, whether the page is moving, and the resulting settled screen. Do not label normal large-to-compact title animation as a duplicate-heading bug.

Apple documents page-style `TabView` for paging, but the sources reviewed provide no promise that it permanently retains all page scroll state. Replacing this custom pager with a `TabView` would therefore require its own verification and would expand the change. ([PageTabViewStyle](https://developer.apple.com/documentation/swiftui/pagetabviewstyle))

## Available APIs and their practical limits

| API | Available on iOS | Relevant behavior and limit |
| --- | --- | --- |
| `ScrollViewReader` / `ScrollViewProxy.scrollTo` | 14+ | Programmatically scrolls to an identified child. It does not report the current offset. Invoke the proxy from an action or change handler, never during content-builder execution. ([Reader](https://developer.apple.com/documentation/swiftui/scrollviewreader)) |
| `scrollPosition(id:anchor:)` | 17+ | Reads and writes a target identity and attempts to maintain visibility through changes. Apple's recipe requires a scroll target layout and demonstrates `ScrollView` with `LazyVStack`; it does not demonstrate exact List offset restoration. ([ID position](https://developer.apple.com/documentation/swiftui/view/scrollposition(id:anchor:))) |
| `ScrollPosition` | 18+ | Supports an identity, point, or edge. Identity positions maintain visibility through relevant content changes; an explicit point does not automatically adapt to content-size changes. Its example likewise uses a scroll target layout. ([ScrollPosition](https://developer.apple.com/documentation/swiftui/scrollposition)) |
| `onScrollGeometryChange` | 18+ | Observes transformed scroll geometry. Attach to the specific List, not an ancestor containing several scrolling pages: Apple says the latter observes only the first scroll view and logs a runtime issue. Avoid updating broad app state on every geometry tick. ([Geometry observation](https://developer.apple.com/documentation/swiftui/view/onscrollgeometrychange(for:of:action:))) |

Availability was checked against Apple's documentation metadata. The browser exposed Apple's Markdown endpoint for API pages; when its reader could not accept that content type, the same primary-source Markdown was read directly.

If retaining visited native pages becomes too expensive, own a scroll bookmark outside the removable subtree, keyed by `LibraryPage` and semantic snip or clipboard-entry ID. Define how deleted or filtered anchor content falls back to a surviving neighbor. Prototype actual List support for the chosen restore API before promising exact offset preservation. Row identity restoration can preserve context while changing the within-row offset, especially for tall text or attachments. An exact-position requirement needs offset and adjusted-inset verification, not just a row-ID assertion.

## macOS comparison: code risk, not a confirmed report

The reported behavior is on iOS; the user has not confirmed a corresponding Mac defect. Read-only inspection nevertheless finds the same page-lifetime risk in [PanelTabPager.swift](../../SnipSnap/PanelTabPager.swift): it renders `displayedPages` by stable `PanelTabPage` identity, temporarily includes the incoming and outgoing pages, and then sets `displayedPages = [target]` at animation completion. Nonanimated selection changes also retain only the target. The departing scroll subtree is removed, so the same SwiftUI lifetime reasoning applies. ([Demystify SwiftUI](https://developer.apple.com/videos/play/wwdc2021/10022/))

The Mac content uses native SwiftUI **`ScrollView` with `LazyVStack`**, rather than the iOS `List`. [SnipListView.swift](../../SnipSnap/SnipListView.swift) wraps that scroll view in `ScrollViewReader` and uses pinned section headers. Its explicit `scrollTo` calls reveal newly added snips, center a snip being edited, preserve the selected snip's visibility when sort changes, and follow keyboard selection. Its `hasScrolledFromTop` state records a Boolean for header appearance, not a saved scroll bookmark. [ClipboardViews.swift](../../SnipSnap/ClipboardViews.swift) also uses a ScrollView with pinned section headers and a local `hasScrolledFromTop` Boolean; the inspected clipboard implementation has no scroll-position restoration binding or scroll reader.

[ContentView.swift](../../SnipSnap/ContentView.swift) supplies these views to `PanelTabPager`. It preserves composer drafts separately but does not pass an external per-page scroll offset or anchor to either list view. Its search and empty-result branches can also replace content structure. No explicit restoration on page return was found in these four files. Existing imperative scrolling for edit, add, sort, or keyboard actions should remain intentional if Mac preservation is implemented later.

Mac headings use the app's [PanelListHeader](../../SnipSnap/PanelUI.swift) and pinned section-header behavior. They do not use iOS's large-to-compact navigation title mechanism. This inspection supports a **potential Mac scroll reset**, not a claim that Mac reproduces the user's issue or that its headings share the iOS failure. A future Mac check should scroll A and Clipboard to different positions, switch away and back with the visible tab strip and trackpad gesture, and check focus, keyboard selection, search, and resize. Launch that check only through `scripts/run.sh`; no Mac runtime check was performed for this comparison.

## Runtime reproduction on iOS

The parent exercised the unmodified app at commit `cadad9024e0f3db46d916ad1fac3532e16519573`, using the Debug `SnipSnapiOS` scheme, isolated **Snip Snap Dev 4**, and an iPhone 17 Pro Simulator running **iOS 26.5**. Both launch and fixture setup used `scripts/run.sh --ios-simulator --simulator-id <selected-simulator>`. The existing `SNIP_SNAP_UI_TEST_LONG_LIST` fixture populated a disposable local test store with 24 snips; no account or live iCloud checks were involved.

The minimized workflow was: return Inbox to the top, scroll vertically, record a visible snip's identity and Y position, swipe horizontally to Clipboard, and swipe back to Inbox. A temporary agent-device harness asserted that the same snip returned within 3 points of its previous position and checked that both page switches actually reached their destinations.

Initial invocation: `python3 /tmp/snip-scroll-repro.py 1`. The result was **FAIL: swiping away and back reset list position**. Before switching, “Fixture 11” was at Y ≈ 261.7 and the Inbox navigation bar was 54 points high. After switching back, that snip was outside the visible hierarchy, the first snip (“Fixture 23”) was visible again, and the navigation bar was 106 points high. Inspected before/after screenshots showed the compact title on the scrolled screen and the large title on the returned screen. These are diagnostic artifacts in temporary local storage, not repository fixtures.

A completed bounded repeat, `python3 /tmp/snip-scroll-repro.py 3`, reproduced the reset in **3/3 attempts**. Each attempt restored the same top-of-Inbox starting state before scrolling. The sampled snips were Fixture 11, Fixture 10, and Fixture 11; all disappeared from the returned visible hierarchy, and every navigation bar changed from 54 to 106 points. An intermediate repeat had already captured two equivalent reset comparisons when an extra screenshot command stalled; that run was stopped, optional screenshots were removed from the harness, and the completed three-attempt run above was performed separately.

This verifies a swipe-induced scroll reset and a corresponding compact-to-large title change. It does **not** prove that the proposed retention change fixes the reset, that all reported interactions share this cause, or that two titles remain visible simultaneously. Search, menus, editing, canceled swipes, iPad, physical hardware, and Mac runtime behavior remain untested. Product code was left unchanged for this research task.

## Proposed validation

Run every real-app check through `scripts/run.sh`, using its isolated Dev app. A compile check through `scripts/build.sh` cannot establish scrolling or title behavior.

1. Populate at least three lists and Clipboard with enough varied-height content to scroll. Record a partially visible top row and its position. Switch A → B → C → Clipboard → A by swiping, then by the visible picker. Verify each page retains its own position.
2. Test one page at the top and another deeply scrolled. Confirm the top page has its native large title and the scrolled page its compact title after switching and after transitions settle. Capture any duplicate title with the exact preceding action.
3. Cancel and reverse a partial page swipe, perform quick successive swipes, and repeat with Reduce Motion. Verify outgoing and incoming pages have coherent titles and the selected page accepts input afterward.
4. Enter and leave search; edit a snip; edit a list title; open and dismiss a menu or sheet; focus and dismiss the composer keyboard. These change hierarchy or available viewport space and must not silently reset a nonempty page.
5. Pin, delete, reorder, or filter content near the saved position. Distinguish expected movement from changed data from a page returning to its first row. Test empty-to-nonempty and nonempty-to-empty transitions separately.
6. Rotate and resize on supported iPhone and iPad layouts; increase Dynamic Type. Verify preserved content context and native title alignment rather than assuming a numeric offset survives a layout change unchanged.
7. Visit many lists and inspect responsiveness and memory. Inactive retained pages must be inaccessible to VoiceOver, untappable, and unable to claim focus or present controls. Deleted lists must stop being retained.

The iOS reproduction above establishes the baseline failure. The broader checks here describe the remaining acceptance surface, rather than claiming every workflow was exercised.

## Implementation follow-up: 2026-10-03

The compact iOS pager now retains visited page subtrees while those pages remain in the library. Transition frames still control what is visible, and inactive pages remain disabled, untappable, and hidden from accessibility. Deleting or canceling a list removes that page from retention. Retention lasts for the current compact library presentation, not across app relaunch or replacement with the iPad split layout.

Both collection screens keep their native List behind search results. The saved-snip List uses an explicit empty query so typing in global search cannot remove its hidden source rows. The existing model projection still defaults to the model's query for other callers. Empty-state messages overlay the same List, giving newly created lists a native scrolling container before their first snip. Native title modes remain centralized and unchanged.

Inactive pages no longer invalidate shared feedback or retain active editing focus, reorder mode, or attachment preview presentation. Search hides the source editor's interactive presentation so its draft can remain model-owned while search owns the visible editor. Editor file/photo/camera and preview bindings also read the current page/search owner when accessed, so a cached native source cell cannot present the same draft's controls from behind search. Source ownership uses the current collection host, rather than the draft's original list; a snip moved to another list or Inbox after list deletion remains editable there.

New UI regression checks cover repeated page swipes, search dismissal, and canceling/saving a new list before returning to a scrolled source list. They compare a visible snip's Y position within 3 points and the native navigation bar's settled height against its own baseline. The new-list check also verifies an expanded title before and after adding the first snip. The swipe and search checks were observed failing before their corresponding fixes and passing afterward on the iOS 26.5 iPhone Simulator; new-list coverage also passed.

Run these checks through `scripts/run.sh --ios-simulator --simulator-id <selected-simulator> --ui-test <method>`:

- `testPageSwipePreservesListPositionAndTitle`
- `testSearchPreservesListPositionAndTitle`
- `testNewListCreationAndCancellationPreservePreviousListPosition`

Attachment preview preparation now rejects a request if page or search ownership changes while it waits, including an away-and-back round trip. The same ownership check suppresses stale failure alerts while retaining background diagnostics; current failures still alert, and stale failures cannot replace a newer unrelated error. Source pages cancel their tracked preview task on deactivation, search entry, and disappearance, and check the live selected page before presenting. Clipboard copy feedback has one model-owned expiry task that restarts on each successful copy; hidden source and search presenters only read its state. Hidden lists also avoid observing each character of the active page's global search query. Automatic thumbnail preparation and decoding inherit source page/search activity; its task cancels when that source becomes hidden, and activation restarts eligible preparation. Hidden sources do not retry on cache invalidation or foregrounding. Hidden thumbnails release their decoded image state and render a placeholder; activation restores the image through the existing shared cache. The cache limit bounds that cache, not the entire native page hierarchy. Search results and other visible attachment consumers retain their existing preparation behavior.

## Performance sanity check

Retention trades extra native view memory for uninterrupted scroll and navigation state. It creates subtrees as pages are visited, releases deleted/canceled pages, and ends with the compact presentation. It does not impose a fixed cache limit: after visiting every list, every surviving page can be mounted. Only transition-visible pages calculate changing motion offsets; retained hidden pages stay at a constant offscreen offset so native navigation chrome remains outside the current viewport. Each native collection build evaluates its source snip projection once, including when computing recovery and empty states. Shared model changes can still update retained lists, and the current snip projection filters the full snip array per list. Large libraries therefore need a separate CPU and memory profile.

The parent measured the Debug Dev app on the same iOS 26.5 iPhone Simulator, using an isolated local gathering fixture: seven saved-snip lists (two snips in Inbox, six empty custom lists) and empty Clipboard. The fixture was seeded, then relaunched through `scripts/run.sh` so only the selected Inbox started mounted. The workflow visited every page, swept through all pages and back three more times, then settled. macOS `footprint` measured the simulator process's memory footprint, rather than RSS.

| Checkpoint | Process footprint |
| --- | ---: |
| Only Inbox visited | 184.08 MiB |
| All eight pages visited | 236.85 MiB |
| First repeat sweep | 237.10 MiB |
| Second repeat sweep | 238.10 MiB |
| Third repeat sweep and settled | 237.56 MiB |

This run added about 53 MiB between first-page and all-page checkpoints, then stayed within about 1 MiB across repeat sweeps. It does not attribute that entire increase to retention: first-use framework work, rendering caches, and simulator compression can contribute. A 10-second idle CPU-time sample did not increase at the counter's resolution. No frame-rate or latency benchmark was taken, so this is evidence against continued growth during that workflow, not proof of smoothness on a physical device.

A second disposable text fixture contained **20 saved-snip lists with 24 snips each (480 total), plus empty Clipboard**. It was generated offline from the existing test store schema, then loaded and driven only through the isolated Dev app. It contained no attachment bytes or account data. The parent checked the actual active page and rows at the sampled checkpoints; snapshots exposed exactly one native navigation bar after visiting five, ten, and twenty lists and Clipboard.

| Populated-fixture checkpoint | Process footprint |
| --- | ---: |
| Only Inbox visited | 218.50 MiB |
| All 20 saved-snip lists visited | 344.38 MiB |
| All 21 pages, returned to Clipboard | 355.06 MiB |
| Return tour through the saved lists | 378.60 MiB |
| Further full return-and-tour traversal | 380.06 MiB |
| Settled | 379.97 MiB |

The final footprint was about **161 MiB above the first-page checkpoint**. Memory increased during initial visits and warming return traversals; the last two traversal checkpoints differed by about 1.5 MiB, and the settled sample stayed at that level. This is a substantial memory tradeoff, not a fixed memory ceiling or a before/after attribution to retention alone. The profile covered the retention and activity gates before the final inactive-image-state cleanup; the fixture has no images, so it provides no evidence for that cleanup's attachment-memory benefit.

A subsequent manual check scrolled Inbox and two custom lists to distinct positions, switched away and back, and compared each saved row's Y position and navigation bar height. All four return comparisons preserved the row exactly at the sampled coordinate and retained a 54-point compact navigation bar. This extends the empty-destination regression evidence to three populated pages, without establishing the complete gesture or accessibility matrix.

The eight-page fixture is deliberately light, and the larger fixture is text only. Hundreds of visited lists, longer populated lists, attachments, physical-device memory pressure, and iPad resizing remain unprofiled. If those measurements make retention unsuitable, use the per-page bookmark alternative above and verify exact List restoration before replacing the current behavior.

No macOS code was changed. Physical devices, iPad layout changes, attachment-heavy and very large libraries, and the complete acceptance matrix above still require separate evidence.

## Final verification

The final implementation passed **188 IOSAppModelTests and six UI workflow tests**, with zero failures, through `scripts/run.sh`. The UI batch covered repeated swipe restoration, search restoration, new-list cancellation/save/first snip, a retained inline draft after its original list was deleted, search editing, and attachment-viewer edge-swipe blocking. The new editor-host regression failed at the expected ownership assertion before the fix and passed afterward.

A final manual Inbox → Clipboard → Inbox check preserved Fixture 11 at Y ≈ 217.7 points and the native compact navigation bar at 54 points. Its clean screenshot was visually checked. A separate ordinary image fixture also restored its thumbnail after a page round trip and search dismissal; this verifies basic restoration, without measuring attachment-heavy memory or cache eviction. These final checks supplement the populated-page and performance evidence above.
