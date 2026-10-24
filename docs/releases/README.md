# Release notes

Read the [changelog](../CHANGELOG.md) for stable release history.

This directory keeps the published notes for stable and beta releases.
Each release uses `Snip-Snap-VERSION.md` for GitHub, `-mac.txt` for Sparkle,
and `-ios.txt` for TestFlight or the App Store. Beta filenames include
`-beta.BUILD` after the version. Older releases may only have Markdown notes.

The publish and promotion scripts add new notes here automatically.
Stable promotion also refreshes `docs/CHANGELOG.md` from these notes and the
update feed. To regenerate it locally, run
`/usr/bin/ruby scripts/release-notes.rb changelog .` from the repository root.
The planned marketing version lives in [Config/release.json](../../Config/release.json).
Use `./scripts/set-release.sh MAJOR.MINOR.PATCH` to update it and Xcode together.

See the [release checklist](../release-checklist.md) for delivery steps and
[GitHub Releases](https://github.com/sreejithraman/snip-snap/releases) for downloads.
The Sparkle feed stays at the repository root so installed apps keep the same
update URL.
