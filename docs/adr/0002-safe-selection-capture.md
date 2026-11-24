# 0002: Bound Copy capture and use Accessibility as a fallback

## Context

Apps expose selections in different ways. Copy can provide text and images, while Accessibility can provide text when Copy does not. Snip Snap must not leave the user's clipboard changed or save content from the wrong app.

## Decision

Read exposed text through Accessibility first, including a bounded parent search, and hold it as the fallback. Take a bounded clipboard snapshot, then queue a short Command-C cycle for the same front app so Snip Snap can collect text and images. Accept only the expected clipboard change. Use the Accessibility text when Copy returns no text or the Copy cycle fails. Restore the snapshot unless a newer writer has changed the clipboard. If any clipboard type cannot be read into the snapshot, skip Copy, because the clipboard could not be restored in full, and use the Accessibility text alone.

## Consequences

Snip Snap needs Accessibility access and must run outside the Mac App Sandbox. Capture can fail on a timeout, app switch, clipboard race, or restore error. Those failures are safer than saving the wrong content or replacing newer clipboard data. Copy is the normal capture path even when Accessibility exposes text because it can also retain images.
