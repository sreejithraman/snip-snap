# 0011: Use one checked release version and build number

## Context

GitHub, Sparkle, Homebrew, and the signed app must agree on each release. A
reused version, build number, tag, ZIP, or DMG can leave users on different
builds that claim to be the same release. Passing values only through the shell
also leaves no clear record in Git.

## Decision

Keep the next public version and build number in `release.json`. Use stable
`MAJOR.MINOR.PATCH` versions. Before 1.0, a patch contains fixes or small polish
and a minor version contains a feature or an intentional break. After 1.0, use
a major version for a break, a minor version for a compatible feature, and a
patch for a compatible fix.

Start the build number at 1. Increase it each time we send an artifact to Apple,
and never reset it. Never reuse or replace a published version, build number,
tag, ZIP, DMG, appcast entry, or Homebrew cask version. Keep prereleases out of
the stable appcast and cask.

Release only the clean commit at public `origin/main` after all tests pass. The
release scripts must check the manifest, Xcode settings, prior tags, prior
appcast builds, signed app metadata, and release checksums. Each release sends
one signed DMG to Apple. Apple creates tickets for the DMG and its nested app.
Staple the DMG and the exported app. The direct-install DMG keeps the signed app
covered by its outer ticket. Package the separately stapled copy of that same
signed app build as the ZIP used by Sparkle and Homebrew. If publishing stops,
resume only from the exact accepted Apple submission and only when any existing
GitHub release, appcast entry, and cask match those files and checksums.

## Consequences

Each release starts with a small pull request that runs `scripts/set-release.sh`
to update `release.json` and the matching Xcode values. If we send a failed
build to Apple, it consumes its build number. A bad public release gets a new
patch and build rather than changed files under an old version.
