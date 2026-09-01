# 0015: Isolate data when the Apple Account changes

When a device signs out of iCloud or changes Apple Accounts, Snip Snap will stop cloud writes and isolate the prior account's local cache. It will ask whether to keep that cache as a local-only copy or remove it from the device. It will not show or upload the prior account's data under the new account. This preserves pending work without allowing data to cross account ownership without consent.

## Consequences

The app must observe CloudKit account changes and keep account caches separate from both the local-only store and other account caches. A temporary CloudKit failure must not look like an account change or cause the app to remove cached data. Recovery and removal paths need tests that cover sign-out, sign-in to the same account, and a switch to a different account.
