# 0002: Bound Copy capture and use Accessibility as a fallback

## Context

Apps expose selections in different ways. Copy can provide text and images, while Accessibility can provide text when Copy does not. Snip Snap must not leave the user's clipboard changed or save content from the wrong app.

## Decision

Take a bounded clipboard snapshot, then queue a short Command-C cycle for the same front app so Snip Snap can collect text and images. Accept only the expected clipboard change. If Copy has no text, read exposed text through Accessibility, including a bounded parent search. Restore all readable clipboard items and types unless a newer writer has changed the clipboard.

## Consequences

Snip Snap needs Accessibility access and must run outside the Mac App Sandbox. Capture can fail on a timeout, app switch, clipboard race, or restore error. Those failures are safer than saving the wrong content or replacing newer clipboard data. Copy is the normal capture path even when Accessibility exposes text because it can also retain images.
