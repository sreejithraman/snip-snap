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

The matrix builds the Mac app, the iPhone Simulator app, and the iPad
Simulator app. It also checks that each iOS app contains
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
interruption test on both device families. It also runs the iCloud limit,
Share, and local attachment actions. Last, Safari opens the embedded Share
extension with the main app open, closed, and unable to migrate. These process
tests use ad-hoc Simulator signing and no Team ID. The default Simulator names
match the CI image. Override them without checking in a device ID:

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
```

`Config/Local.xcconfig` and `Config/Local.entitlements` stay out of Git. The
entitlement file must include the App Group and CloudKit capabilities tied to
those settings. Do not put a team ID, profile name, device ID, certificate, or
local path in a tracked file.

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

For a signed iPhone or iPad device build, use the iOS scheme. A generic device
build checks signing without storing a device ID:

```sh
./scripts/signed-lane-preflight.sh device \
  --scheme SnipSnapiOS \
  --configuration Debug \
  --destination 'generic/platform=iOS'
xcodebuild \
  -project SnipSnap.xcodeproj \
  -scheme SnipSnapiOS \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/snip-snap-device \
  build
```

The preflight lists missing setting names but does not print their values.
The iOS build embeds the Share extension. Confirm the signed device build in
Xcode before installing it on a registered device.

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

## Check tracked inputs

```sh
./scripts/tracked-input-policy.sh
```

This check reads files tracked by Git. It rejects personal signing settings,
home paths, and device IDs. It permits public product names and clear fake
test values. Existing Git history stays as-is unless a separate security
check finds a real credential. Rotate any such credential before cleaning
history.
