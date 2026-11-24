# 0015: Keep the local library when the Apple Account changes

When a device signs out of iCloud or changes Apple Accounts, Snip Snap turns off
sync and keeps the cache as a writable local-only library. The app keeps the
library automatically, without a Keep or Remove prompt. The kept library can
rejoin only its original account. On that account it resumes its own sync
generation. If the control record is gone, names different zones, or names a
different generation,
[ADR 0024](0024-keep-the-local-library-after-icloud-data-reset.md) applies: the
enable stops with the iCloud data reset notice, and the next explicit enable
merges the library into the current generation or a fresh one.

Snip Snap checks the Apple Account at the start of a sync cycle and when it
receives an account-change notification or engine event. A temporary CloudKit
failure pauses sync without changing the local library. A missing or changed
control record requires confirming the account before interpreting it as a
collection reset.

This replaces the original isolation of the prior account's data (#420).
