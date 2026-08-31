# Build and signing setup

Snip Snap keeps its public build settings in `Config`. A clean checkout does
not select an Apple team or signing identity.

## Build and test

Use Xcode 26 or later:

```sh
./scripts/build.sh
./scripts/test.sh
```

These commands do not sign the app. They need no Apple Developer account,
certificate, provisioning profile, or CloudKit access.

Run the full unsigned build matrix before a pull request or release:

```sh
./scripts/build-matrix.sh
```

The matrix builds the Mac app in Debug and the iPhone and iPad Simulator apps
in Debug. It also checks that each iOS app contains
`SnipSnapShareExtension.appex`. The defaults use generic Simulator
destinations, so the command needs no device ID. To build against installed
Simulator names, pass overrides:

```sh
./scripts/build-matrix.sh \
  --iphone-destination 'platform=iOS Simulator,name=Example iPhone' \
  --ipad-destination 'platform=iOS Simulator,name=Example iPad'
```

CI runs `scripts/test.sh`, this build matrix, and the named Simulator release
tests on a clean checkout. These commands set `CODE_SIGNING_ALLOWED=NO` for
app builds.

Run the same release tests on an iPhone and iPad Simulator:

```sh
./scripts/release-matrix-tests.sh
```

This command runs the generated 25 MiB upload, download, hash, cache, and
interruption test on both device families. It also checks the 100 MiB total
boundary, quota and interrupted-upload retries, the iCloud limit action,
Share, and local attachment actions. Last, Safari opens a fixed loopback page
and invokes the embedded Share extension with the main app open, closed, and
unable to migrate. An exclusive run lock guards the loopback port. These
process tests use ad-hoc Simulator signing and no Team ID. The default
Simulator names match the CI image. Override them without checking in a device
ID:

```sh
./scripts/release-matrix-tests.sh \
  --iphone-destination 'platform=iOS Simulator,name=Example iPhone' \
  --ipad-destination 'platform=iOS Simulator,name=Example iPad'
```

Run the full iOS UI suite when changing an iOS workflow:

```sh
xcodebuild \
  -project SnipSnap.xcodeproj \
  -scheme SnipSnapiOS \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=Example iPhone' \
  -derivedDataPath /tmp/snip-snap-ios-ui-tests \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:SnipSnapiOSUITests \
  test
```

## Run the local Dev app

```sh
./scripts/run.sh
```

With no local signing setup, this command uses ad hoc signing. The Dev app
uses local data and receives no CloudKit entitlement. macOS may ask for a new
Accessibility grant after the app changes.

For a stable developer-signed identity, copy the example once:

```sh
cp Config/Local.example.xcconfig Config/Local.xcconfig
```

Set `DEVELOPMENT_TEAM` in the copied file. Xcode can show your team in its
Signing settings. `Local.xcconfig` stays out of Git. The Dev command detects
the team and uses automatic Apple Development signing without changing the
project file.

Forks can also replace the public bundle, App Group, and CloudKit container
names in that local file.

## Cloud Dev and physical-device builds

Cloud and physical-device lanes need all of these inputs:

- An Apple development team
- A bundle ID registered to that team
- Registered App Group and CloudKit container names
- The lane's entitlement file

Keep the values in `Config/Local.xcconfig` on a development Mac. CI can pass
the same setting names as secret inputs. Set these names in the local file:

```text
DEVELOPMENT_TEAM = <your team>
SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER = <your registered bundle root>
SNIP_SNAP_APP_GROUP_IDENTIFIER = <your registered App Group>
SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER = <your registered iCloud container>
CODE_SIGN_ENTITLEMENTS = Config/Local.entitlements
SNIP_SNAP_IOS_APP_CODE_SIGN_ENTITLEMENTS = Config/Local.entitlements
```

`Config/Local.xcconfig` and `Config/Local.entitlements` stay out of Git. The
entitlement file must include the App Group and CloudKit capabilities tied to
those settings. Do not put a team ID, profile name, device ID, certificate, or
local path in a tracked file.

Cloud Dev uses a separate installed-app identity. By default, the build adds
`.clouddev` to the configured bundle root and App Group. For example:

```text
App:             <bundle root>.clouddev.ios
Share extension: <bundle root>.clouddev.ios.share
App Group:       <App Group>.clouddev
CloudKit:        <the same container>, Development environment
```

Register the two Cloud Dev App IDs and the Cloud Dev App Group with the team.
Give both targets the Cloud Dev App Group. Give only the main app the existing
CloudKit container. If the registered names differ, set
`SNIP_SNAP_CLOUD_DEV_PRODUCT_BUNDLE_IDENTIFIER` and
`SNIP_SNAP_CLOUD_DEV_APP_GROUP_IDENTIFIER` in ignored `Local.xcconfig` or the
protected CI job.

The separate bundle IDs let Cloud Dev and TestFlight stay installed together.
The separate App Groups keep their device data apart. The shared CloudKit
container still keeps Development data apart from Production data.

For a Mac Cloud Dev build, run the preflight and build with the same scheme,
configuration, and destination:

```sh
./scripts/signed-lane-preflight.sh cloud \
  --scheme SnipSnap \
  --configuration Debug \
  --destination 'generic/platform=macOS'
xcodebuild \
  -project SnipSnap.xcodeproj \
  -scheme SnipSnap \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/snip-snap-cloud-dev-mac \
  build
```

For a signed Cloud Dev iPhone or iPad build, use the guarded command. A generic
device build checks signing without storing a device ID:

```sh
./scripts/cloud-dev.sh build
```

The command runs the Development-environment preflight, selects the fixed Cloud
Dev IDs, uses the orange-scissors `AppIconDev`, and labels the app **Snip Snap
Dev**. It embeds the matching Share extension. TestFlight keeps the plain
icon, production IDs, production App Group, and Production CloudKit data.

To check one registered phone without saving its ID in Git, pass Xcode's local
destination at run time:

```sh
./scripts/cloud-dev.sh build --destination 'id=<your local device ID>'
```

Confirm the signed build in Xcode before installing it. The preflight lists
missing setting names but does not print their values.

Maintainers with valid Cloud Dev signing and container access can run the
small fake-versus-real transport contract:

```sh
SNIP_SNAP_RUN_CLOUD_DEV_TRANSPORT_CONTRACT=1 \
  ./scripts/cloud-dev-transport-contract.sh
```

The command runs the signed-lane preflight first. It then checks that the fake
and real development-container transports follow the same save, fetch,
confirm, and delete rules. Contributor CI does not run this command. If the
local signing or container setup is missing, leave the release checklist item
unchecked; do not report a skipped run as a pass.

## Make an official release

Official releases use the team from `Local.xcconfig` or
`SNIP_SNAP_DEVELOPMENT_TEAM`. They need these environment variables:

```sh
export SNIP_SNAP_SIGNING_IDENTITY='YOUR_SIGNING_IDENTITY'
export SNIP_SNAP_NOTARY_PROFILE='YOUR_NOTARY_PROFILE'
./scripts/release.sh
```

The identity can come from the local Keychain instead of the first variable;
the release command finds the matching Developer ID identity for the selected
team. The notary profile name points to credentials stored by `notarytool` in
the Keychain. CI can pass the same named inputs through its secret store.

The release command creates its export options in a private temporary folder.
No personalized export file, certificate name, profile, or team ID belongs in
Git.

## Prepare a TestFlight build

TestFlight uses a separate iOS lane. It does not change the Mac release path.
First, copy the production entitlement template:

```sh
cp Config/TestFlight.example.entitlements Config/TestFlight.entitlements
```

The copied file stays out of Git. Its names come from `Local.xcconfig` or the
same run-only `SNIP_SNAP_*` inputs used by protected CI. It selects CloudKit
Production for the main app. The Share extension keeps its App Group-only
entitlement.

Check the signed settings without uploading:

```sh
./scripts/signed-lane-preflight.sh testflight \
  --scheme SnipSnapiOS \
  --configuration Release \
  --destination 'generic/platform=iOS'
```

Create and inspect a release archive:

```sh
./scripts/testflight.sh archive
```

The command runs the public policy and package tests, then the Simulator build
matrix. The iOS release gate leaves the Mac app-host tests to their normal CI
job. It checks the signed app and embedded Share extension for the expected
bundle IDs, team, App Group, production CloudKit access, version, build,
privacy manifests, and dSYM. It rejects CloudKit access on the Share extension
and asks Xcode to use App Store Connect distribution signing during export.
An automatically signed archive may still use Apple Development signing;
Xcode replaces that signature when it exports the build for App Store Connect.
The archive also records its source commit and whether the worktree was clean.
An upload rejects an archive that does not match the exact clean public commit.
You can create an archive on a feature branch to test the lane, but do not send
that archive through Organizer.

For the first beta, open the archive in Xcode Organizer and use **Distribute
App**, **TestFlight & App Store**, automatic signing, and symbol upload. Do not
let Xcode change the version or build number.

After that flow has worked once, a maintainer can upload the checked archive:

```sh
SNIP_SNAP_CONFIRM_TESTFLIGHT_UPLOAD=YES \
  ./scripts/testflight.sh upload
```

The upload command runs only from a clean commit that equals `origin/main`.
It can use an Apple account already signed in to Xcode or the run-only
`SHOWROOM_APPLE_*` inputs supplied by the global Showroom Apple profile. The
command writes its export options in a private temporary folder, turns off
Xcode build-number changes, and keeps logs under the ignored `artifacts`
folder.

Never run the upload from pull-request CI. A later CI job must use a protected,
manual environment that does not expose secrets to forks.

## Check tracked inputs

```sh
./scripts/tracked-input-policy.sh
```

This check reads files tracked by Git. It rejects personal signing settings,
home paths, device IDs, Apple credential files, and private-key blocks. It
permits public product names and clear fake test values. Existing Git history
stays as-is unless a separate security check finds a real credential. Rotate
any such credential before cleaning history.
