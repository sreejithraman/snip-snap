<p align="center">
  <img src="SnipSnap/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" height="128" alt="Snip Snap app icon">
</p>

<h1 align="center">Snip Snap</h1>

<p align="center">
  Save text and files on your Mac. Use them when you need them.
</p>

<p align="center">
  <a href="https://sree.world/snip-snap">Website</a> ·
  <a href="https://github.com/sreejithraman/snip-snap/releases/latest">Latest release</a>
</p>

## Install

```sh
brew install --cask sreejithraman/tap/snip-snap
```

Snip Snap needs macOS 26 or later. Grant Accessibility access when asked so
system-wide capture and Shift shortcuts can work.

## Keep snips ready

- Press Left Shift twice to capture selected text.
- Press Right Shift twice to open your snips.
- Save text and files, sort them into lists, and find them fast.
- Keep up to 100 clipboard items, or pause and clear clipboard history at any
  time.

Everything stays in a small panel where you can edit, copy, or drag snips back
into your work.

## Command-line access

The Homebrew cask installs the `snipsnap` CLI with the app. `add` saves text to
Inbox or a named list and marks its origin as Agent. It works while the app is
closed. Read, update, and delete commands require the running app. Use
`snipsnap --help` for the full syntax.

```sh
snipsnap lists create Research
snipsnap add "Follow up tomorrow"
printf '%s' "Review the release notes" | snipsnap add \
  --list Research --session-title "Release follow-ups"
snipsnap list --json
snipsnap show SNIP_UUID --json
printf '%s' "Revised note" | snipsnap update SNIP_UUID \
  --if-updated-at UPDATED_AT
snipsnap show SNIP_UUID --json
snipsnap delete SNIP_UUID --if-snip-revision SNIP_REVISION --yes
snipsnap lists list
snipsnap lists show Research --json
snipsnap lists rename LIST_UUID Reading --if-list-revision LIST_REVISION
snipsnap lists show LIST_UUID --json
snipsnap lists delete LIST_UUID --if-list-revision LATEST_LIST_REVISION --yes
```

Agent snips show a sparkle and their session title. When no title is supplied,
the CLI records the current Git branch instead. Session IDs are never shown.

Agents running in this checkout discover the repo skill at
`.agents/skills/snip-snap`. An explicit request UUID makes an uncertain
read or edit safe to check with `snipsnap status REQUEST_UUID` before retrying.
For an uncertain `add`, retry it with the same `--request-id`, text, and options.
For snip updates, copy `updatedAt` from the latest `list` or `show --json`
result. For deletion, copy that snip's value from `snipRevisions` in the same
result. A content or metadata change invalidates the deletion revision.
For list rename and delete, copy `listRevision` from the latest
`lists show --json` result. A change to the list settings or its membership
invalidates that revision; reread after a conflict.
List create and rename return `resultListID` in JSON, including on a retry.
The CLI asks the running app to process read and edit requests. The app updates
the UI and schedules iCloud sync after writes. Only `add` stays queued when the
app is closed. If the same library is active at the next launch, the app imports
the add. An add made before Snip Snap establishes a library, or one queued for
a library that is no longer active, appears in Needs attention for an explicit
Inbox choice. Compact write results and uncertain request markers remain on
disk so reusing an old request UUID cannot run a mutation twice. Successful
read results are removed after display.
The private command handoff directory is excluded from backups. Expired pending
requests and read results are pruned while the app runs, at its next launch, or
on a later CLI read, edit, delete, or `status` command. `add` and `help` do not
prune this directory.
If a queued destination list disappears before import, the app preserves the
snip in Inbox.

## Private by default

Snip Snap needs no sign-in and has no tracking. Snip Snap does not send
local-only data to CloudKit. Turn on iCloud Sync to sync saved snips and
attachments.

With iCloud Sync on, Snip Snap stores saved snips and attachments in your
private iCloud database. Snip Snap's maintainers cannot inspect your private
records in CloudKit Console. Apple encrypts synced data in transit and at rest;
Snip Snap stores user fields as encrypted values and file bytes as `CKAsset`
data. Those user fields and attachments are end-to-end encrypted only when
Advanced Data Protection is on for your iCloud account.

Snip Snap supports iCloud Sync attachments up to 25 MiB each and 100 MiB total
per snip. These are Snip Snap limits, not Apple limits. Local-only attachments
do not use these sync limits.

Release builds contact the public update feed to check for new versions.

## Build from source

Use Xcode 26 or later with Apple’s Metal toolchain. A clean checkout needs no Apple Developer account:

```sh
xcodebuild -downloadComponent MetalToolchain
./scripts/build.sh
./scripts/test.sh
./scripts/run.sh
```

The Dev app uses ad hoc signing by default. See
[Build and signing setup](docs/building.md) for optional developer signing,
Cloud and device needs, fork identifiers, and official releases.

## License

Snip Snap uses the MIT License. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
