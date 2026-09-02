# Release delivery sanity check

Research date: September 2, 2026

## Verdict

The release design is sound:

- A protected `main` workflow builds one iOS and Mac beta from the same commit
  and build number.
- TestFlight gets the iOS archive while GitHub Releases, Sparkle, and a Homebrew
  tap carry the Mac archive.
- Stable promotion reuses the tested Mac files and records which tested iOS
  build to select in App Store Connect instead of rebuilding either app.
- Maintainer keys and production IDs stay in the protected `apple-release`
  environment, so a clean public checkout still builds without them.

The current Homebrew path fix is not correct, though. Fix that before the next
beta run. The rest of the beta path matches the source docs reviewed below.

## Fix the Homebrew path first

The pinned `Homebrew/actions/setup-homebrew` action adds Homebrew's `bin` and
`sbin` folders to `GITHUB_PATH` on macOS. GitHub makes entries written to
`GITHUB_PATH` available to later steps in the same job.
[Pinned action source](https://github.com/Homebrew/actions/blob/a657b8b0cd35d0f65cce41fce9b24cf054b49869/setup-homebrew/main.sh#L41-L83),
[path setup](https://github.com/Homebrew/actions/blob/a657b8b0cd35d0f65cce41fce9b24cf054b49869/setup-homebrew/main.sh#L143-L147),
[GitHub `GITHUB_PATH` docs](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#adding-a-system-path)

Do not build a brew path from `steps.homebrew.outputs.repository-path`. The
action describes that output as the repository checkout path, and its source
sets it only when the workflow repository is Homebrew itself or a Homebrew tap.
Snip Snap is neither, so this output is empty and the current expression becomes
`/bin/brew`.
[Action metadata](https://github.com/Homebrew/actions/blob/a657b8b0cd35d0f65cce41fce9b24cf054b49869/setup-homebrew/action.yml#L31-L39),
[output implementation](https://github.com/Homebrew/actions/blob/a657b8b0cd35d0f65cce41fce9b24cf054b49869/setup-homebrew/main.sh#L171-L196)

The failed build 14 log proves that Homebrew ran from `/opt/homebrew`, yet the
later script could not resolve `brew`. After the setup action, add a small step
that resolves and checks the executable, then writes its exact path to
`GITHUB_ENV`. Search the two macOS prefixes that the pinned action itself uses:
`/opt/homebrew/bin` and `/usr/local/bin`. Pass that checked path to the publish
script. This gives a clear failure at setup time and works on both Apple silicon
and Intel runners. Add the same pinned setup and resolve steps to stable
promotion; `promote-stable.yml` currently calls `brew style` without setting up
Homebrew.

## TestFlight: upload is not the last step

`xcodebuild -exportArchive` with `destination = upload` is a valid upload path.
Apple then processes the build before it appears in App Store Connect. A
successful upload means Apple received the file, not that the build is ready to
install. Apple sends a status email, exposes delivery details in **Build
Uploads**, and says to contact support if processing lasts more than 24 hours.
[Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/),
[view build processing](https://developer.apple.com/help/app-store-connect/manage-builds/view-builds-and-metadata/)

For each first usable beta:

1. Wait for upload status **Complete** and inspect any warnings.
2. Confirm the beta status is **Ready to Submit**, **Ready to Test**, or
   **Testing**, not **Missing Compliance** or **Invalid Binary**.
3. If export compliance is missing, answer it on the build. The existing
   `ITSAppUsesNonExemptEncryption = NO` should avoid this only while the shipped
   code remains exempt.
4. Add the build to an internal tester group and add **What to Test**, unless
   that group has automatic distribution on.
5. Install from TestFlight and do the short iPhone sync and Share extension
   check in `docs/release-checklist.md`.

Apple lets internal groups receive builds automatically, but this is a setting
on the group; an upload alone does not prove that testers received it. Builds
remain testable for 90 days. External testing needs a group, test details, and
usually TestFlight App Review for the first build.
[Build statuses](https://developer.apple.com/help/app-store-connect/reference/app-build-statuses/),
[export compliance for beta builds](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-export-compliance-information-for-beta-builds/),
[internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/),
[external testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/)

## Sparkle is set up the right way

Using Sparkle's `generate_appcast` with the private EdDSA key is the recommended
way to sign update archives. The app's public key stays in `Info.plist`; the
private key stays in the protected environment. The feed uses the numeric build
as `sparkle:version` and `0.5.0` as `sparkle:shortVersionString`, which matches
Sparkle's internal-build guidance.
[Sparkle publishing](https://sparkle-project.org/documentation/publishing/)

The single-feed beta design is also right. Beta items have
`<sparkle:channel>beta</sparkle:channel>`, the app returns `beta` from
`allowedChannels(for:)` only when the user opts in, and all users still see the
default channel. Stable promotion removes the beta channel from that exact item.
Sparkle says channels are for updates that later return to the default channel,
which is this case.
[Sparkle channels](https://sparkle-project.org/documentation/publishing/#channels)

After a beta publish, check the public `appcast.xml` for the new build, fetch the
ZIP URL from the enclosure, and run the Mac app's **Check for Updates** path from
a stable build with beta updates both off and on. After stable promotion, check
that the item has no beta channel and that its URL and EdDSA signature still
refer to the same tested ZIP.

## Homebrew is set up the right way after the path fix

`snip-snap@beta` follows Homebrew's required `@<channel>` name for an alternate
channel. A fixed version and SHA-256 are preferred to `:latest` and
`sha256 :no_check`. `Casks/` is the standard folder in a tap, and
`conflicts_with cask: "snip-snap"` is valid for two apps that cannot share the
same installed app name.
[alternate-channel casks](https://docs.brew.sh/Cask-Cookbook#casks-for-alternative-release-channels),
[checksums](https://docs.brew.sh/Cask-Cookbook#stanza-sha256),
[cask conflicts](https://docs.brew.sh/Cask-Cookbook#stanza-conflicts_with),
[tap layout](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap#casks)

The printed install command should name the tap for a fresh machine:

```sh
brew install --cask sreejithraman/tap/snip-snap@beta
```

Homebrew recommends a fully qualified direct install because it adds the tap in
the same command. The short `brew install --cask snip-snap@beta` form is safe to
show only after the user has tapped `sreejithraman/tap`.
[installing from a tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap#installing)

Homebrew also requires cask files to live in a registered tap. Styling an
absolute cask path in an unrelated temporary clone fails even when the Ruby is
valid. The publisher should tap `sreejithraman/tap`, get its checkout with
`brew --repository sreejithraman/tap`, write the cask there, and then run
`brew style --cask`. This keeps validation on the same file that gets pushed.
[tap command](https://docs.brew.sh/Manpage#tap-options-userrepo-url),
[tap layout](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap#casks)

After publish, test on a clean tap state: install the fully qualified beta cask,
launch it, run `brew upgrade --cask`, and remove it. Before stable promotion,
run the same checks for the stable cask and confirm the beta/stable conflict has
the user experience intended by the project.

## Order for the next run

1. Replace the invalid `repository-path` brew expression and cover both beta
   publish and stable promotion.
2. Run the release tests and a focused clean-runner check that proves
   `brew style --cask` executes.
3. Merge the small fix. Let the new beta run finish; do not promote while any
   release job is red.
4. Check the GitHub prerelease, all attached checksums, the beta appcast item,
   and the beta cask from a clean tap.
5. Wait for TestFlight processing, clear any warning or compliance state, add
   the build to the internal group, then install and test it.
6. Promote only that tested version and build. Verify the stable GitHub release,
   default Sparkle item, stable cask, and App Store Connect handoff.

The likely remaining failures are access, not design: the publish token may
lack write access to either repository; branch protection may reject direct
pushes from the release token; the Sparkle private and public keys may not
match; the internal TestFlight group may not auto-distribute; or Apple may flag
processing, export compliance, privacy, or signing warnings. Each check above
finds one of those faults before a public stable release.
