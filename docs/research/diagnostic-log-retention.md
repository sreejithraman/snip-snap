# Diagnostic log retention

Research date: 2026-10-24. Design proposal only; no implementation or app checks.

## Recommendation

Keep a small, persistent, local diagnostic history and continue emitting Apple
unified logs. Make sharing an explicit user action. This works for other users
and contributors without a paid service, maintainer account, or local setup.

**Proposed defaults, not industry requirements:** retain events for up to **7
days**, with a **10 MiB total history cap**. Reserve **2 MiB** of that budget for
warnings/errors and their bounded operation context; routine events may use the
other **8 MiB**. Roll each stream at **1 MiB or 24 hours**, whichever comes first.
Delete expired events and evict oldest segments within each budget. Errors can
still expire or exhaust their own budget: this protects them from routine noise,
not from every possible loss. Seven days is an upper retention target, never a
guaranteed minimum under a disk cap.

## Starting evidence

The supplied, previously verified investigation found `AppDiagnostics.swift`
emits through `Logger(subsystem: "SnipSnap", category: "Operations")` and an
`AppDiagnosticEventStore` in bundle-specific `Caches/SnipSnapDiagnostics`.
The history and export are bounded at 64 KiB; each append reads and atomically
rebuilds the bounded file. Fields are structured and allowlisted, excluding snip
content, filenames, paths, and account/record IDs. Latest sync health and last
successful fetch/send are separate from history rotation.

On October 24, installed version 0.6.1 (159) held 352 events from 14:18–16:32
EDT, with previous-day operational events gone. The macOS query found no
SnipSnap subsystem events for the previous day, although installed-app framework
diagnostics existed. This is one observed workload, not a measured retention
guarantee or proof that all system diagnostics were absent. This note does not
re-run or extend that investigation.

## Common approaches

- **System logs only:** little app-owned storage machinery and useful framework
  correlation. Apple normally keeps debug/info in memory; notice/error/fault
  persist only within a storage limit, with old entries purged when it fills.
  Apple also provides privacy controls for interpolated values. This does not
  supply an app-controlled seven-day history or a predictable support export.
  Keep it complementary. ([Apple logging](https://developer.apple.com/documentation/os/generating-log-messages-from-your-code))
- **Rolling local files:** directly supports later user reports and offline use.
  Size rotation bounds individual files; time rotation creates manageable
  segments; retention separately removes old data. CocoaLumberjack documents
  rolling on either size or elapsed time, plus archive-count and disk-quota
  limits. Seven daily files need not mean seven days when size rolls happen
  sooner. Its policy is a useful example, not a dependency recommendation.
  ([file rolling](https://cocoalumberjack.github.io/Classes/DDFileLogger.html),
  [archive limits](https://cocoalumberjack.github.io/Protocols/DDLogFileManager.html))
- **Memory ring:** cheap, bounded recent context without disk history. Useful
  for verbose breadcrumbs, but loses evidence at termination/relaunch. A
  persistent ring survives relaunch; its byte cap alone still lets repetitive
  events displace yesterday's failure. These are design tradeoffs, not reasons
  to retain unlimited detail.
- **Optional hosted reporting:** can bring reports to maintainers sooner, but
  introduces network transfer, service operation, consent, and server retention
  decisions. Crash reports, operational history, and product analytics serve
  different purposes. None requires enabling the others. Keep hosted reporting
  outside this default; local diagnostics and export must work independently.

## Storage location and durability

Apple distinguishes app support data from disposable caches. On iOS,
Application Support is backed up by default; Caches is excluded and may be
purged. On macOS, sandboxing changes the effective Library location. Resolve
directories through Foundation rather than hardcoding a user's home path.
([Apple filesystem guide](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html))

For the proposed persistent history, use a bundle-specific diagnostic directory
under **Application Support on both platforms**, separate from the user store.
This is a product choice: it lets the app manage history that cannot be recreated
after eviction. **Caches remains reasonable only for explicitly disposable,
best-effort history**, with that limitation stated to users.

On macOS, **Library/Logs** is also a conventional log location, documented by
Apple. It does not itself establish a rotation or backup policy; sandbox access
and backup behavior still need verification. Application Support gives this
proposal one consistent cross-platform policy.
([macOS Library directories](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/MacOSXDirectories/MacOSXDirectories.html))

Mark the diagnostic directory excluded from backup and preserve the exclusion
when replacing files. Apple says exclusion is guidance, not a guarantee that
data never appears in backups. The cited backup guidance concerns iCloud device
backup; do not assume identical macOS Time Machine behavior. Keep diagnostics
outside document sync and avoid treating any directory as a confidentiality
boundary. ([Apple backup guidance](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup))

## Practical policy details

All numbers and behavior below are proposed choices:

- Aggregate identical routine events over **60 seconds**, preserving count,
  first/last timestamp, and outcome changes. Summarize repeated errors too;
  retain their first occurrence and meaningful transitions. Keep bounded context
  near warnings/errors so the reserved stream remains useful.
- Record UTC timestamp, severity, event/schema version, and app version/build
  on every event or segment. Start a new segment after an upgrade. Keep OS
  version/platform in segment context; avoid persistent device identifiers.
- Keep the existing privacy allowlist. Apple's `Logger` redaction does not
  automatically protect custom files: encode only approved fields, including
  sanitized error codes rather than arbitrary error descriptions.
- Preserve latest health and last-success state independently. History expiry
  must not reset them. This note proposes no sync behavior changes.
- Offer **Share diagnostics** with a chosen date range, actual available range,
  app/OS context, latest health, and explicit truncation/gap notices. Default
  to the last **24 hours**, with up to the available seven days selectable.
  Let users inspect the export before sharing; never upload automatically.
- Give export staging a separate **5 MiB total uncompressed budget**, independent
  of the 10 MiB history. Filter by range, prioritize failures/context, and state
  omissions instead of silently clipping. Remove staging after sharing finishes
  where practical and clean abandoned exports on the next launch. User-saved
  copies belong to the user and outlive app cleanup.
- Provide **Clear diagnostic history** and **Record local diagnostics** off/on.
  Explain that clear removes app history/staging, while off stops app-owned
  recording; neither erases prior OS logs or user-shared copies. Keep diagnostic
  controls separate from sync-health reset.

Do not simply enlarge the current rewrite-on-every-append file to 10 MiB.
Append to small segments with serialized writes, bounded records, and explicit
cleanup. Handle partial final records and disk failures without blocking normal
app work. Any implementation should verify crash/relaunch behavior, event
storms, age/cap enforcement, upgrade metadata, export bounds, controls, and
backup attributes. No performance improvement is claimed without measurement.

## Limits and decision

Choose the local policy now; tune 10 MiB toward 20 MiB only if representative
measurements show useful history is routinely lost. The one 64 KiB sample does
not establish event rates across users. Cleanup runs when the app executes, so
expired files can remain while it is closed; purge before reading/exporting.
Uninstall, manual deletion, storage failure, clock changes, and writes still in
flight can shorten history. No fixed minimum coverage or exact timed deletion
is promised.

Sources were read on 2026-10-24. Apple filesystem pages are archived guidance
(macOS directory page updated 2018-04-09); CocoaLumberjack references identify
themselves as 3.7.0 documentation. Current Apple logging and backup Markdown was
retrieved directly from Apple's documentation endpoints. No new dependency or
asset is proposed; license review remains required before adding one. Storage,
backup, and retention behavior remain implementation verification work.
