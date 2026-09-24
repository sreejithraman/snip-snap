# 0003: Route global actions through left and right Shift

## Context

Snip Snap has one panel. It needs fast system-wide capture, window access, and clipboard access without adding more panels.

## Decision

Treat two left Shift taps as Capture Selection. Treat two right Shift taps as Show or Hide Snip Snap, and focus the active list's composer when showing it. Keep snip keys active only while the snip list is the current command target.

Treat Command plus two Left Shift taps as Open or Hide Clipboard. Command must stay held through both taps. It opens the same panel on Clipboard. If that view is already open on the active Space, it hides the panel. During an inline edit, it keeps the panel and current page open so the draft stays available. Let people change all three global shortcuts.

The [search mode decision](../search-mode.md) replaces the original focus behavior: opening Clipboard closes search and focuses the Clipboard list.

## Consequences

The app must register and validate global key input, preserve user shortcut settings, and keep snip commands away from editors and text fields. A real cross-app check needs Accessibility access and a physical key press.
