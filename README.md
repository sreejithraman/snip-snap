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

## Add snips from an agent

The `snipsnap` CLI adds text to Inbox or a named list and marks its origin as
Agent. The Homebrew cask installs it with the app. Pass text as an argument or
on standard input:

```sh
snipsnap add "Follow up tomorrow"
printf '%s' "Review the release notes" | snipsnap add \
  --list Research --session-title "Release follow-ups"
```

Agent snips show a sparkle and their session title. When no title is supplied,
the CLI records the current Git branch instead. Session IDs are never shown.

Agents running in this checkout discover the repo skill at
`.agents/skills/add-to-snip-snap`. The skill uses a stable request UUID so a
retry does not add the same snip twice.
The CLI asks the running app to import the request so the UI updates immediately
and iCloud sync is scheduled. If the app is closed, the request stays queued
until the next launch.
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
