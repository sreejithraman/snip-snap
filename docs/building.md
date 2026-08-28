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

## Cloud and physical-device builds

Cloud and physical-device lanes need all of these inputs:

- An Apple development team
- A bundle ID registered to that team
- Registered App Group and CloudKit container names
- The lane's entitlement file

The shared preflight checks all required inputs at once and lists missing
setting names without printing their values:

```sh
./scripts/signed-lane-preflight.sh cloud --configuration CloudDev
./scripts/signed-lane-preflight.sh device --destination 'generic/platform=iOS'
```

The commands that build those lanes will be added with the iOS and CloudKit
work. Until then, the preflight is the shared contract for those commands.

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
