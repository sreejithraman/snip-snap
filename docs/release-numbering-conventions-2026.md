# Release numbering conventions

Research date: September 1, 2026

## Finding

Use one planned numeric marketing version and one increasing numeric build
number across iOS and Mac. A beta for the planned `0.5.0` release can use:

| Surface | Beta | Stable promotion |
| --- | --- | --- |
| Apple bundle | `0.5.0 (7)` | `0.5.0 (7)` |
| TestFlight and App Store | upload build `7` | select build `7` |
| Sparkle | version `7`, short version `0.5.0`, channel `beta` | move the item to the default channel |
| GitHub | `v0.5.0-beta.7` prerelease | `v0.5.0` on the same commit |
| Homebrew | `snip-snap@beta`, version `0.5.0-beta.7` | `snip-snap`, version `0.5.0` |

Apple requires `CFBundleShortVersionString` to contain three period-separated
integers. Its current `CFBundleVersion` reference allows one to three numeric
parts. Keep `beta`, commit IDs, and other labels out of both values.
[Apple marketing version](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring),
[Apple build version](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion)

Use the same marketing version and build number in the app and each extension.
Apple lets a TestFlight build become the App Store build, so stable promotion
does not need a new archive.
[Choose an App Store build](https://developer.apple.com/help/app-store-connect/manage-builds/choose-a-build-to-submit),
[TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)

Sparkle compares its version to `CFBundleVersion`. Put beta state in its
`beta` channel and let beta users see both beta and default updates. On stable
promotion, remove that channel from the existing item and keep the archive,
signature, and version unchanged.
[Sparkle channels](https://sparkle-project.org/documentation/publishing/#channels),
[Sparkle version comparison](https://sparkle-project.org/documentation/api-reference/Classes/SUStandardVersionComparator.html)

Homebrew's standard alternate-channel name is `snip-snap@beta`. Use a fixed
version and checksum rather than `:latest`.
[Homebrew alternate release channels](https://docs.brew.sh/Cask-Cookbook#casks-for-alternative-release-channels)

The `MAJOR.MINOR.PATCH` form is useful for the product even though Snip Snap does
not claim strict Semantic Versioning for a public programming interface. Use a
patch before 1.0 for fixes and small polish, and a minor version for a useful
feature set or intentional break. The `-beta.7` form belongs in Git and
Homebrew labels, not in Apple bundle values.
[Semantic Versioning 2.0.0](https://semver.org/)

## Build source

Use one long-lived beta workflow's `github.run_number` plus a fixed migration
offset. GitHub raises that number for each new workflow run and keeps it on a
rerun. Do not include `github.run_attempt`, since a retry should not become a
new build.
[GitHub Actions contexts](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#github-context)

Start the generated series above the highest old build. If the workflow must be
replaced, raise the offset above every build already sent out. Record the final
number, commit, workflow run, checksums, and upload results with each beta.

## Change from the old policy

Keep only the planned marketing version in `release.json`. Pass the generated
build number to the archive scripts. This removes counter-only pull requests
while leaving a record in GitHub Actions, TestFlight, Sparkle, and each GitHub
release.
