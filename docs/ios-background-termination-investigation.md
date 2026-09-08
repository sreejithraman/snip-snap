# iOS background termination fix

September 8, 2026. The fix protects store work during background execution and
stops work at expiry checks. Unit tests reproduce the missing protection and
unsafe commit after expiry. The iOS termination itself still needs a device
check.

## Evidence and cause

The three retrieved TestFlight logs from builds 32 and 43 report
`EXC_CRASH (SIGKILL)` and `RUNNINGBOARD 0xdead10cc`. Apple describes this code as
holding a file or SQLite lock during suspension in its
[SIGKILL documentation](https://developer.apple.com/documentation/xcode/sigkill).
Raw logs and tester details stay outside the repository.

Build 43 shows an automatic CloudKit fetch calling
`CloudFullSyncCoordinator.applyAutomatically`, then `commit`, then
`CloudFullSyncPersistence.applyStaged`, then
`SwiftDataSnipLibrary.commitCloudFullBatch`. The worker was in a SwiftData
fetch at line 352 of that build's batch-commit source. The method holds a
`SnipStoreFileLock` through its return. The app had no background assertion
around that work. The report does not identify which lock prompted the kill.

The build 32 logs show SQLite/Core Data work, including `ftruncate` in one
report. Their app frames still need symbolication before assigning them to
the same call path. Comparing build 43 (`70bfe99`) with build 47 (`13908a0`)
showed no later fix to store locking or suspension.

## Change

`SnipStoreFileLock` now requests iOS background time before opening its lock
file or accessing SwiftData. It releases the file lock before ending the
assertion, including error exits and activity deallocation. macOS keeps its
blocking lock wait and does not request an assertion. Transfer metadata reads
acquire protection after the earlier snapshot read has released its lock.

The implementation uses Foundation's
[performExpiringActivity](https://developer.apple.com/documentation/foundation/processinfo/performexpiringactivity(withreason:using:)).
This avoids sending a synchronous store operation to the main actor. The
Foundation work callback and expiry callback both wait for lock cleanup.
Expiry sets a flag that the store can check without an actor hop.

A denied request throws before opening the lock file. Lock waiters use
nonblocking `flock` with expiry checks rather than waiting without a limit.
Attachment scans check expiry between files and before hashing or copying,
including scans that find no changed rows. Batch commits check expiry between
records and major phases; store writes
check again before saving. Expiry during a batch rolls back its context,
leaving the staged batch and prior engine state intact for replay. A save
already in progress finishes under the same assertion. After a successful
save, the batch uses its validated state instead of loading the database again;
expiry defers remaining file cleanup to the next sweep. Sync treats expiry
as pending work, including setup that must resume on a later sync.

The stage/apply/confirm order and the store's transaction boundaries stay
intact. The fix does not change account isolation, merge policy, or reset
handling in ADRs 0014, 0015, 0016, and 0024. It adds no dependency or entitlement.

## Regression checks

Before the fix, the lock tests failed because no background time was requested
and a denied request did not prevent opening the lock file. The batch test
failed because simulated expiry still committed the remote list and engine
state and removed the staged batch. The setup test threw instead of retaining
pending setup.

The new tests cover:

- Background time begins before lock access and ends after unlock.
- Denial and file-open failure release resources.
- Expiry stops a contended lock waiter and keeps protection through cleanup.
- Both Foundation callbacks wait for cleanup; initial denial does not deadlock.
- An expired batch rolls back, retains its stage and engine state, and replays
  exactly once.
- Setup interrupted by denied background time resumes on the next sync.
- Attachment expiry stops later reads, removes uncommitted upload files, and
  allows retry; unchanged scans also stop.
- Transfer metadata reads request their own background time.
- Expiry after save preserves the committed result and defers file cleanup;
  the next sweep removes the leftover files.

Run the focused checks with:

```sh
swift test --package-path Packages/SnipSnapLibrary --filter 'SnipStoreBackgroundActivityTests|CloudFullRecordPersistenceTests|CloudCollectionCoordinatorTests|CloudSyncIssueMapperTests'
```

Run the full shared-library suite with `swift test --package-path
Packages/SnipSnapLibrary`, and compile both apps with `scripts/build.sh`.
The PR records the results for its final head. No build product was launched.

## Remaining device check

Use a signed Dev app with its own App Group and CloudKit development
environment through the repo's run path. Keep the TestFlight store separate.
Repeat automatic fetches while entering the background, without a debugger
keeping the process alive. Check a large collection, attachment metadata,
background-time expiry, and foreground replay. Compare process survival and
termination logs with the old build, and verify that edits remain intact.

A synchronous SwiftData call cannot be preempted by these checks. It must
return before expiry can unwind the operation. A call or migration that
exceeds the OS cleanup allowance can still cause a termination. The tests
prove admission, cleanup ordering, and replay; they do not prove that every
physical-device database operation finishes within that allowance.

No build was uploaded or distributed as part of this work.
