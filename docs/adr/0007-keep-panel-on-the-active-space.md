# 0007: Keep the panel on the active Space

## Context

Showing a transparent floating panel on every macOS Space can leave stale background samples and visual artifacts during Space changes. Keeping a panel on one fixed Space instead makes the global shortcut switch the user's desktop away from their current work.

## Decision

Keep the Snip Snap panel on one Space at a time and use AppKit's move-to-active-Space behavior. When the shortcut runs on another Space, bring the existing panel to that Space. Hide it only when it is already visible on the active Space.

## Consequences

Snip Snap does not remain visible on every Space. A user invokes it again after moving to another Space, and the same panel moves there without changing Spaces. Full-screen and multi-display behavior still needs live macOS checks because the collection option alone does not fully describe WindowServer behavior.
