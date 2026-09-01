# 0014: Preserve data across sync mode changes

Changing between local-only mode and iCloud sync will merge records by stable identity instead of replacing one collection with another. Snip Snap will compare the local and server records with their last shared version and merge fields that changed on only one side. When both sides changed the same user field differently, the current server value remains on the original snip and Snip Snap saves the local value as a recovered snip. Device and upload dates will not choose a winner. Attachments merge by stable identity, and ordering resolves in a fixed way. This favors visible extra data over silent loss.

## Consequences

A recovered snip appears beside the main snip with a visible badge and explanation, or in Inbox when its prior list no longer exists. It keeps a link to the current snip and records the fields that conflicted. The badge and Needs Attention status open a comparison with Keep Current, Use Recovered, Keep Both, and Edit actions. A choice changes only conflicting fields and must refresh if the current snip changed while the review was open. Review does not block sync or open as an urgent prompt.

When a remote delete competes with an offline edit, the original remains deleted and the edited version becomes a recovered snip in Inbox. If a remote list deletion competes with an offline move into that list, the list remains deleted and the snip moves to Inbox. Sync status will explain that move. Manual order will use sync-safe sort keys with stable IDs as tie-breakers. A server-accepted update will settle concurrent moves of the same snip without a recovered copy or warning.

A user may turn off sync while offline by copying the current local cache after the app warns that newer iCloud changes may be absent. Turning off sync leaves the iCloud copy intact. The app will report Off, Setting Up, On, Syncing, and Needs Attention without promising that all remote changes have arrived.
