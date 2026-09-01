# Snip Snap

Snip Snap keeps saved snips apart from temporary clipboard history and groups those snips into lists.

## Language

**Snip**:
A saved piece of text with optional file attachments.
_Avoid_: Clip, item, capture item

**Clipboard entry**:
A temporary record of content copied through the Mac clipboard.
_Avoid_: Snip, clipboard snip

**List**:
A named group that owns an ordered set of snips.
_Avoid_: Section, folder

**Inbox**:
The built-in list that receives snips when no other list applies.
_Avoid_: Panel, snip list

**Panel**:
The main Snip Snap window that shows lists, snips, and clipboard history.
_Avoid_: Inbox, inbox window

**Local-only mode**:
A per-device storage choice that keeps saved snips on that device and does not use iCloud.
_Avoid_: Offline mode, local account

**iCloud sync**:
A per-device storage choice that keeps saved snips in a local cache and syncs them through the user's private iCloud database.
_Avoid_: Cloud mode, online mode, Snip Snap account

**Recovered snip**:
A saved copy created when a three-way merge finds different edits to the same field. It links to the current snip until the user chooses which edit to keep or keeps both as normal snips.
_Avoid_: Conflict, error copy

**Done / Not Done**:
The two completion states and action labels for a snip.
_Avoid_: Mark Done, Mark Not Done, Complete, Incomplete

**Sync generation**:
A random identity for one version of the user's synced collection. Devices must match it before they may upload.
_Avoid_: Schema version, account ID

**Marketing version**:
The public three-part app version, such as `0.5.0`. It names one planned stable release across iOS and Mac.
_Avoid_: Release number, short version

**Build number**:
One internal positive integer for a set of iOS and Mac files built from the same commit. It always rises and never resets.
_Avoid_: Beta number, run attempt

**Beta**:
A tested build offered through TestFlight, the Sparkle beta channel, a GitHub prerelease, or the `snip-snap@beta` cask before stable release.
_Avoid_: Prerelease version in an Apple bundle

**Promotion**:
Publishing the exact tested beta files as stable without rebuilding them or changing their marketing version or build number.
_Avoid_: Rebuild, rerelease
