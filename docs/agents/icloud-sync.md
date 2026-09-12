# iCloud sync work

## Choose the check

Read [ADR 0028](../adr/0028-let-cksyncengine-schedule-normal-sync.md) before
changing sync ownership, scheduling, retry timing, or event handling.

Use [the live CloudKit check](../building.md#run-the-live-cloudkit-check) for
commands, signing setup, cache locks, and saved results. That guide owns the
run instructions. Use the existing runner for signed transport tests and the
repo's Dev run path for app checks; leave build-output bundles unopened.

[Normal tests](../building.md#build-and-test) use the existing fake transport
and need no account or signing.
It tests repeatable failures and ordering, but cannot prove CloudKit behavior.
For changes to the transport or downloaded-file access, run the live check when
signed Development access is available. If it is unavailable, report that gap
and keep the account-free tests usable.

A live pass proves the contract's text, attachment-byte, and deletion checks
between two clients in one Mac test host. Physical Mac-to-iPhone push delivery,
background resume, and Production throttling need separate evidence. The linked
run guide records the current gap in the required device run path; report that
gap rather than treating a local-only Dev run as cloud proof.
Report the command, exit status, passed/skipped counts, and saved result path.
A skip or a prior run against changed code is not proof of the current change.

## Gotchas from live testing

- **First fetch:** the real transport withholds record writes until the initial
  fetch is confirmed. The contract creates its zone first, confirms queued
  events, fetches, then writes records. Keep explicit contract transfers separate
  from normal app scheduling described in ADR 0028.
- **Event order:** checkpoints can precede a returned batch. Confirm in order,
  stop at the target batch, and reject a different batch. A fresh engine can
  report initial sign-in; the contract validates the current account before
  acknowledging an account event.
- **Shared fake logic:** both adapters use the record mapper. Matching fake and
  real responses can hide the same mapping bug. Compare received fields with the
  original draft and downloaded bytes with the original file.
- **File grants:** CloudKit can grant access to an attachment while denying
  reads of ancestor cache directories. `CloudAssetFileCopy` uses
  `AttachmentFileIO.copyGrantedRegularFile` for that trusted SDK URL. Keep its
  regular-file and leaf-symlink checks. Keep untrusted imports on `RootedDirectory`;
  the granted-file API trusts path ancestors.
- **Failure evidence:** read the runner's stage error and saved test summary
  before diagnosing an app failure. The original live test failed because its
  startup sequence was wrong; the expanded test then found a real file-access
  bug. A harness failure and an app failure need different fixes.
- **Cleanup:** the contract deletes only its unique test zone and checks that it
  is gone. A killed process cannot run cleanup, and an account change can block
  it. If cleanup fails, preserve the reported zone and account context. Confirm
  the same account and the exact test zone before any manual removal; never
  clear app zones to get a passing test.

Keep signing values, device IDs, logs, and account data in ignored local state.
Commit durable lessons here, not machine-specific run receipts. Keep the live
contract and its focused tests together when changing these checks.
