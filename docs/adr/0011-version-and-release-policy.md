# 0011: Check the marketing version and generate the build number

## Context

GitHub, Sparkle, Homebrew, TestFlight, and the signed apps must agree on each
release. The old policy kept both the marketing version and build number in
`release.json`. That made each beta need a pull request which changed only a
counter. A single maintainer should not need to edit that counter by hand.

## Decision

Keep the next planned marketing version in `release.json`. Use numeric
`MAJOR.MINOR.PATCH` versions. Before 1.0, a patch contains fixes or small polish
and a minor version contains a feature or an intentional break. After 1.0, use
a major version for a break, a minor version for a compatible feature, and a
patch for a compatible fix.

Generate one build number for each beta delivery from a long-lived GitHub
Actions workflow. Use that workflow's `github.run_number` plus a fixed offset
which puts the first generated number above every old build. Keep the iOS app,
Share extension, and Mac app on that same number. Never reset the number. If the
workflow must be replaced, raise the offset above every build already sent out.
A rerun keeps the original build number. Do not include `github.run_attempt`.

Keep beta labels out of Apple bundle versions. For a build such as `0.5.0 (7)`,
use `v0.5.0-beta.7` for its GitHub prerelease, the `beta` Sparkle channel, and
`snip-snap@beta` with version `0.5.0-beta.7` for Homebrew. The stable tag is
`v0.5.0`.

Promote the exact tested files. Select the same TestFlight build for the App
Store. Move the same Sparkle item from the beta channel to the default channel.
Attach byte-for-byte copies of the tested Mac files to the stable GitHub release
and point the stable cask at the same archive checksum. Do not rebuild for
promotion.

Never reuse or replace a build number for different files, a published tag, an
asset, an appcast entry, or a cask version. A bad stable release gets a new
patch version and build.

Build betas only from a clean commit on public `origin/main` after all tests
pass. Record the marketing version, build number, commit, workflow run, file
checksums, and upload results. The release scripts must check those values, the
signed app metadata, prior tags, and prior feeds. If publishing stops, resume
only from the matching files and records.

Keep the existing Mac signing and notarization rules. Staple the DMG and the
exported app. Use the separately stapled app in the ZIP for Sparkle and
Homebrew.

## Consequences

Changing the planned marketing version still needs a normal code change. Beta
builds do not need counter-only pull requests. Protected CI secrets can publish
official builds while forks and normal pull requests keep working without a
maintainer Apple account.

Local compile and Dev builds use `1` as a harmless fallback build number. The
protected beta workflow passes its generated number to both archive scripts, so
the fallback never reaches TestFlight, Sparkle, GitHub, or Homebrew.
