# 0015: Keep the local library when the Apple Account changes

When a device signs out of iCloud or changes Apple Accounts, Snip Snap turns off
sync and keeps the cache as a writable local-only library. The app keeps the
library automatically, without a Keep or Remove prompt. The kept library can
rejoin only its original account and sync generation.

Snip Snap checks the Apple Account at the start of a sync cycle and when it
receives an account-change notification or engine event. A temporary CloudKit
failure pauses sync without changing the local library. A missing or changed
control record requires confirming the account before interpreting it as a
collection reset.

Approved by SIMP-ADR12-15-D1 for SIMP-07.
