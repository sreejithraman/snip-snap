# Release automation plan

## Goal

Give one maintainer a small release path which keeps secrets out of the public
repository:

- Pull requests run tests and unsigned builds.
- The latest app-changing state on protected `main` sends one build to internal
  TestFlight and publishes one public Mac beta.
- A manual stable action promotes that tested build without rebuilding it.

## Release flow

### Pull request

Run the current tests, policy checks, and unsigned Mac, iPhone Simulator, and
iPad Simulator builds. Do not load signing files or release secrets.

### Main beta

Use two long-lived workflows. The candidate workflow has a path filter for app,
package, project, release-script, and build-setting changes. A docs-only merge
should not make a beta. The delivery workflow starts only after a candidate
finishes successfully on `main`.

Cancel an older candidate when a newer app change reaches `main`. Keep one
delivery active and one pending, and do not cancel active delivery. GitHub
replaces an older pending delivery with the newest one. Before signed work, the
delivery checks that its tested commit is still the tip of `main`. Passing that
check marks the delivery as started; a later push does not stop it.

The workflows:

1. Test the full unsigned matrix once in the candidate workflow.
2. Check that the tested commit is still current, then read the planned
   marketing version from `release.json`.
3. Set the build number to the delivery workflow run number plus the migration
   offset, then build iOS and Mac from the same clean commit and number. Local
   release commands still test by default.
4. Upload iOS to internal TestFlight.
   A separate job waits for that exact iOS version and build to finish processing,
   writes its English What to Test notes, then reads them back. Rerun failed jobs
   if notes fail; the successful upload job does not need to run again.
5. Sign and notarize the Mac app.
6. Create a GitHub prerelease such as `v0.5.0-beta.7`.
7. Add the Mac update to the Sparkle `beta` channel.
8. Update `snip-snap@beta` in the Homebrew tap.
9. Save the commit, candidate run and attempt, delivery run and first publishing
   attempt, number, checksums, Sparkle signature, Mac signing and notarization
   results, and TestFlight upload result as release evidence. Keep that asset
   unchanged. GitHub keeps later delivery rerun attempts and their job results
   on the same workflow run.

### Release notes

The prepare job writes notes once from the tested commit and keeps them as a
workflow artifact for both platforms. Beta notes use changes since the nearest
earlier release tag. Stable notes include all changes since the previous stable
tag, rather than just the last beta's changes.

Notes use commit titles for changes to app source. Mac source changes appear in
the Mac list, iOS and Share extension changes in the iOS list, and shared source
changes in both. A title that names only Mac or iOS narrows shared changes to
that platform. Mac- and IOS-prefixed package files also stay with their platform;
localization edits alone do not add the other platform to an app change.
Tests, docs, and publishing commits without app changes do not become notes.
Keep app-change commit titles useful to users and name the platform when needed.

GitHub release notes contain Mac and iOS sections. Sparkle embeds the Mac text
in the appcast, so the update window does not need to fetch a notes file.
TestFlight receives only the iOS text. Each release also saves separate
`-mac.txt` and `-ios.txt` files. The stable release attaches the iOS text and
links it in the workflow summary for the existing App Store handoff: paste it
into What's New when selecting the tested build. Stable promotion does not
submit App Store metadata or send a release for review.

For local beta publishing, `SNIP_SNAP_RELEASE_NOTES_FILE` overrides the GitHub
text. The note generator accepts `SNIP_SNAP_MAC_RELEASE_NOTES_FILE` and
`SNIP_SNAP_IOS_RELEASE_NOTES_FILE` for authored platform text, including shorter
iOS notes when a stable release exceeds Apple's 4,000-character limit. Without
overrides, the script generates notes from the full release checkout. Retries
compare the files, GitHub body, and embedded Mac text with published notes and
stop on a mismatch; they do not rewrite release history.
TestFlight notes follow the same rule: fill missing or blank English notes,
reuse an exact match, and stop if nonempty published text differs.
To set TestFlight notes after a local upload, use the same Apple API key inputs
as `testflight.sh` and run:

```sh
/usr/bin/ruby scripts/testflight-notes.rb BUNDLE_ID VERSION BUILD_NUMBER IOS_NOTES_FILE
```

The helper changes only English TestFlight notes for that exact iOS build. It
does not change tester groups or submit a build for review.

Rerunning a delivery keeps its build number and files. Rerunning a candidate
starts a new delivery run and therefore gets a new build number.

Publish in that order. If a later step fails, keep the prior beta live and rerun
the failed job with the same build and files.

### Stable promotion

Start one manual workflow and enter a recorded beta's marketing version and
build number. It:

1. Check that the beta commit is on `main` and all expected checks passed.
2. Check every file against the saved checksum.
3. Select the existing TestFlight build for App Store release.
4. Create stable tag `vMAJOR.MINOR.PATCH` on the same commit.
5. Attach byte-for-byte copies of the tested Mac files to the stable GitHub
   release.
6. Move the existing Sparkle item from `beta` to the default channel.
7. Update the stable `snip-snap` cask with the same archive checksum.

Apple may still need a manual App Store review and release choice. The workflow
must stop with clear steps when Apple needs that choice.

## Open-source boundary

Keep public defaults, unsigned builds, tests, and fake CloudKit checks in the
repository. Keep these values in one GitHub environment named `apple-release`:

- App Store Connect API key, key ID, and issuer ID;
- Apple signing certificates and their passwords;
- provisioning profiles and production IDs;
- notarization credentials;
- Sparkle signing key;
- Homebrew tap write token.

Restrict the environment to protected `main`. Do not require a reviewer while
there is one maintainer. GitHub masks secrets, but scripts must also avoid
printing them. Fork pull requests must never receive this environment.

## Implementation

The repo implements all nine items above. Keep beta delivery off until
the protected environment has all inputs and one maintainer has checked the
first internal TestFlight and Mac beta.

Do not add a release service, bot account, daily schedule, deployment reviewer,
or automatic issue creation. GitHub Actions logs and reruns are enough for this
project now.

## Done when

- A clean checkout can run all normal checks without secrets.
- A fork cannot read or use maintainer release values.
- The latest app-changing `main` state can make matching iOS and Mac betas.
- A retry does not create another build number or change files.
- Stable promotion uses the exact files users tested.
- Stable and beta Sparkle feeds and Homebrew casks update without crossing.
