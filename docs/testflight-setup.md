# TestFlight setup for Snip Snap

Checked against Apple documentation on August 30, 2026.

## Recommended path

Use one iOS-only App Store Connect record for the production iPhone and iPad
app. Keep the current macOS app on its direct-download release path. Upload the
first iOS build by hand through Xcode Organizer so the team can inspect every
signing choice and Apple warning. Automate the same archive and upload steps only
after that build reaches an internal TestFlight group.

Choose **TestFlight & App Store**, not **TestFlight Internal Only**, if a build
may later go to external testers or the App Store. Apple limits an internal-only
build to internal groups. [Distributing an app for beta testing and
releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)

## One-time Apple setup

### 1. Confirm the account and roles

- Keep the Apple Developer Program membership active and require two-factor
  authentication for App Store Connect access.
- Have the Account Holder accept the latest Apple Developer agreement. A paid
  app or an app with In-App Purchases also needs the Paid Apps Agreement, tax
  details, and banking details; a free app does not need that paid agreement.
- Use an Account Holder or Admin for identifiers, capabilities, certificates,
  and profiles. An Account Holder, Admin, or App Manager can create the app
  record. A Developer can upload builds. An Account Holder, Admin, or App
  Manager must manage external TestFlight testing.

Apple documents the account split in [roles and
access](https://developer.apple.com/help/account/access/roles), [accounts and
roles](https://developer.apple.com/help/app-store-connect/manage-your-team/overview-of-accounts-and-roles),
and [agreements](https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements/).

### 2. Register the production identifiers

Pick the final identifiers before the first upload. The App Store Connect bundle
ID cannot change after a build has been uploaded. [App
information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)

Snip Snap needs:

- One explicit App ID matching the production iOS app bundle ID.
- One explicit App ID matching the Share extension bundle ID.
- One registered production App Group assigned to both App IDs.
- One iCloud container assigned to the main iOS App ID, with iCloud and CloudKit
  enabled.
- Push Notifications enabled on the main iOS App ID so CloudKit can wake the
  app for background changes.
- No CloudKit entitlement on the Share extension. It writes to the shared App
  Group inbox and lets the main app perform cloud work.

Apple explains explicit App IDs in [Register an App
ID](https://developer.apple.com/help/account/identifiers/register-an-app-id),
the shared-container setup in [Configuring app
groups](https://developer.apple.com/documentation/xcode/configuring-app-groups),
and iCloud assignment in [Enable app
capabilities](https://developer.apple.com/help/account/identifiers/enable-app-capabilities).
Apple also requires the containing app and embedded extension to use the same
distribution signing method. [Creating an app
extension](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html)

Use maintainer-owned values through ignored local input or CI secrets. Do not
change the open-source defaults to contain a Team ID, certificate, profile,
private key, or machine path.

### 3. Prepare CloudKit production

TestFlight builds use CloudKit production and cannot use the development
environment. Deploy the finished record types, fields, and indexes from the
development schema to production before uploading. A schema deployment copies
the schema, not the development records, and production schema changes are
additive. [Testing a CloudKit
app](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitQuickStart/TestingYourApp/TestingYourApp.html),
[Deploying an iCloud container's
schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)

Then run one release-signed archive against production and check the signed app,
not just the source entitlement file. Xcode combines the entitlement file,
developer-account data, and project settings when it signs. [Entitlements](https://developer.apple.com/documentation/bundleresources/entitlements)

### 4. Create the App Store Connect record

Create one record with:

- Platform: iOS.
- Name: Snip Snap: Pocket Clipboard.
- Primary language.
- The production main-app bundle ID.
- A stable internal SKU.
- Full or limited team access.

Do not create a second record for the Share extension; it ships inside the iOS
app archive. The existing direct-download Mac app has a different bundle ID, so
it should not be added as a second platform on this record. Apple's multiplatform
single-record flow requires the platforms to share a bundle ID. [Add a new
app](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/)

### 5. Set signing

Start with Xcode's automatic signing for both the iOS app and Share extension.
Select the same paid team for both targets. Xcode can create and update App Store
distribution profiles during archive export.

If the team later uses manual signing, it needs an Apple Distribution
certificate and an App Store Connect provisioning profile for each signed
executable. Each profile must match its explicit App ID and allowed
capabilities. Enabling or changing an App ID capability invalidates old manual
profiles, so recreate them after capability changes. [App Store Connect
provisioning
profiles](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/),
[Enable app
capabilities](https://developer.apple.com/help/account/identifiers/enable-app-capabilities)

### 6. Prepare privacy and compliance

Before the first upload:

- Use the public privacy policy at
  `https://sree.world/snip-snap/privacy`. The policy explains local-only
  mode, optional private-CloudKit sync, data access, retention, deletion, and
  how a user turns sync off or removes synced content. The iOS Settings screen
  links to the same URL. Enter it in App Store Connect as well. Apple requires
  the URL for iOS, and its review rules also require an easy-to-find link inside
  the app. [Manage app
  privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/),
  [App Review Guidelines, section
  5.1.1](https://developer.apple.com/app-store/review/guidelines/#data-collection-and-storage)
- Complete the App Privacy answers. Based on the current design, private
  CloudKit data that Apple holds but the maintainer cannot access should not be
  reported as maintainer collection. Apple says developers do not report data
  Apple collects through services such as CloudKit. Confirm this again against
  the shipped code and every linked SDK before answering **Data Not Collected**.
  [App privacy
  details](https://developer.apple.com/app-store/app-privacy-details/)
- The code audit found only one-way SHA-256 hashes in app code and encryption
  supplied by Apple's CloudKit and operating system. Snip Snap does not add or
  bundle non-exempt encryption. `SnipSnapiOS/Info.plist` records this decision
  as `ITSAppUsesNonExemptEncryption = NO`, which keeps uploads from stopping at
  **Missing Compliance**. Recheck this decision before release if encryption or
  a new linked SDK gets added. [Export compliance
  overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance),
  [`ITSAppUsesNonExemptEncryption`](https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption)
- Add valid privacy manifests for each executable that uses an API requiring an
  approved reason. Snip Snap currently uses `UserDefaults` in the Share
  extension and file timestamp APIs in the app and shared persistence code.
  Audit the archive, choose the approved reasons that match those uses, and add
  the declarations to the correct app and extension bundles. App Store Connect
  does not accept builds that omit required reasons. [Describing use of
  required-reason
  APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api),
  [Privacy manifest
  files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)

App Store screenshots, description, keywords, support URL, age rating,
copyright, category, and other product-page fields are needed before a public
App Store release. They do not block the first internal TestFlight build. [App
version
information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information),
[required properties](https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties)

### 7. Create tester groups

Create an internal group first. Internal testers must be App Store Connect users
with access to the app. Apple permits up to 100 internal testers, and each build
lasts 90 days. [Add internal
testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers)

External testing can wait until the internal build is sound. It permits up to
10,000 testers by email or public link. Before the first external build, add a
beta description, feedback email, review contact, review notes, and demo login
if the app needs one. The first external build needs full TestFlight App Review;
later builds of the same version may not. [Provide test
information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information),
[Invite external
testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers)

For Snip Snap's review notes, state that iCloud sync is optional and off by
default, explain how to enable it, explain that the Share extension appears in
the system Share sheet, and give a short sync test between two devices. The app
has no separate Snip Snap login, so it needs no demo account.

## Repo state

### Already present

- The `SnipSnapiOS` target supports iPhone and iPad and embeds
  `SnipSnapShareExtension.appex`.
- The main app bundle ID and Share extension bundle ID derive from
  `SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER`.
- Both targets carry the shared App Group entitlement. The Share extension has
  no CloudKit entitlement.
- Ignored `Config/Local.xcconfig`, `Config/LocalMac.entitlements`, and
  `Config/LocalIOS.entitlements` inputs exist on
  the current maintainer machine and contain a team, production-name overrides,
  App Group, CloudKit container, and CloudKit capability values. The values stay
  out of Git.
- `scripts/signed-lane-preflight.sh` checks signed development and device lanes,
  including the app/extension App Group match and the rule that only the main
  app gets CloudKit.
- `scripts/build-matrix.sh` checks iPhone and iPad Simulator builds and confirms
  that the Share extension is embedded.
- `release.json`, `Config/Shared.xcconfig`, and ADR 0011 establish one planned
  marketing version. Protected CI generates a rising build number and passes
  the same number to the iOS app, Share extension, and Mac app.
- `Config/TestFlight.example.entitlements` provides a public production template.
  Its ignored copy and all production names remain local or protected CI input.
- `Config/MacRelease.example.entitlements` keeps the direct-download Mac app on
  the same production CloudKit data as TestFlight without reusing Cloud Dev's
  Development entitlement file.
- `scripts/testflight.sh` archives and uploads the iOS app separately from the
  Mac release. Its policy checks the signed app and embedded extension before
  upload.
- The iOS app and Share extension each contain their own privacy manifest.
- `Config/iOSShared.xcconfig` inherits the one version and build from
  `Config/Shared.xcconfig` instead of overriding it.
- `scripts/cloud-dev.sh` gives signed development builds separate bundle IDs,
  a separate App Group, the Development CloudKit environment, a clear name,
  and an orange-scissors icon. Cloud Dev and TestFlight can stay installed at the
  same time without sharing local data.
- `docs/testflight-beta-metadata.md` keeps public beta copy repeatable without
  storing private contact details.

### Gaps before the first upload

1. **Apple-side production registration has not been proved in the repo.** Check
   the two explicit App IDs, shared production App Group, assigned iCloud
   container, main-app Push Notifications capability, current agreements, and
   App Store Connect record. Refresh the main app's provisioning profiles after
   changing a capability.
2. **App Store Connect setup still needs a portal check.** Confirm that
   `https://sree.world/snip-snap/privacy` is set as the privacy-policy URL and
   that the export-compliance answer matches the recorded code audit.
3. **The global Apple publishing profile has not been proved ready.** Keep its
   distribution certificate and App Store Connect API key outside this repo.

## First internal build

1. Finish the gaps above on a clean commit from `origin/main`.
2. Keep the planned marketing version unless this beta starts a new public
   version. The protected beta workflow generates a new build number. Apple
   identifies a build by bundle ID, version, and build string. [Upload
   builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
3. Run the iOS UI tests, signed Cloud Dev contract, and physical-iPhone release
   check. `scripts/testflight.sh archive` runs `scripts/test.sh` and the unsigned
   build matrix itself.
4. Run `scripts/testflight.sh archive`. It archives `SnipSnapiOS` in Release for
   `generic/platform=iOS` and checks the result. An archive cannot come from a
   Simulator build. [Testing a CloudKit
   app](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitQuickStart/TestingYourApp/TestingYourApp.html)
5. Inspect the archive before upload:
   - The bundle IDs match the App Store Connect app and registered extension.
   - The app embeds the Share extension.
   - Both signatures use the expected team. An automatically signed archive
     may still use development profiles; the App Store Connect export replaces
     them with distribution signing.
   - Both signed executables contain the same production App Group.
   - Only the main app contains CloudKit, and its environment is production.
   - The main app has the production push entitlement; the Share extension does
     not.
   - The version matches `release.json` and the build matches the workflow's
     generated value.
   - Privacy manifests and dSYMs are present.
6. In Organizer, choose **Distribute App**, **TestFlight & App Store**, automatic
   signing, and symbol upload. Turn off Xcode's automatic version/build-number
   management because the archive already contains the workflow's value.
7. Wait for App Store Connect processing, resolve export compliance, review all
   warnings, add **What to Test**, and assign the build to the internal group.

Apple accepts uploads from Xcode, Transporter, `altool`, the App Store Connect
API, or Xcode Cloud. The first upload is simplest in Organizer. [Upload
builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)

## Repeat for each beta build

1. Use a clean reviewed commit on `main`. The workflow run number plus its fixed
   offset produces the build number. A retry of the same run keeps the same
   number and verifies the same files; a later run gets a larger number. Never
   reuse a build number for different files. [Build upload
   status](https://developer.apple.com/help/app-store-connect/manage-builds/view-builds-and-metadata)
2. Run the release tests and production-signing preflight.
3. Archive, inspect, and upload the same way.
4. Add clear **What to Test** notes and assign the processed build to the right
   group.
5. Submit external builds for TestFlight review when needed. Apple allows up to
   six TestFlight review submissions in 24 hours. [Invite external
   testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers)
6. Keep the archive, dSYMs, commit, version, build, and App Store Connect delivery
   result together as release evidence.

## Protected beta delivery

`.github/workflows/beta.yml` tests a push to `main`, then uses the protected
`apple-release` environment for signed work. It uploads the iOS build to
TestFlight and publishes the same-number Mac beta to GitHub, Sparkle's `beta`
channel, and the `snip-snap@beta` cask. Set the repository environment variable
`SNIP_SNAP_BETA_DELIVERY_ENABLED` to `true` only after all protected inputs have
been added. Until then, the workflow runs its public test job and skips delivery.

Add these secrets to `apple-release`:

- `APPLE_API_ISSUER_ID`
- `APPLE_API_KEY_ID`
- `APPLE_API_PRIVATE_KEY`
- `APPLE_TEAM_ID`
- `IOS_DISTRIBUTION_CERTIFICATE_BASE64`
- `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`
- `MAC_DEVELOPER_ID_CERTIFICATE_BASE64`
- `MAC_DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `MAC_PROVISIONING_PROFILE_BASE64`
- `MAC_PROVISIONING_PROFILE_NAME`
- `MAC_RELEASE_ENTITLEMENTS`
- `RELEASE_LOCAL_XCCONFIG`
- `SNIP_SNAP_PUBLISH_TOKEN`
- `SPARKLE_PRIVATE_KEY`
- `TESTFLIGHT_ENTITLEMENTS`

`SNIP_SNAP_PUBLISH_TOKEN` needs write access to both the app repo and the
Homebrew tap. The other values hold Apple or Sparkle signing inputs. Keep them
only in the protected environment. The setup job writes them to short-lived
files and a short-lived keychain, then removes those files even after a failed
step.

To publish stable, run **Promote stable release** and enter the marketing
version and build number from the tested beta tag. For example,
`v0.5.0-beta.7` means version `0.5.0` and build `7`. The workflow checks the
beta record, tag, files, and checksums before it updates the stable GitHub
release, Sparkle item, and Homebrew cask. It does not rebuild the app. Its last
step names the same TestFlight build to select in App Store Connect.

It needs secret inputs for the production identifiers, Team ID, distribution
signing material, and upload credentials. An App Store Connect API key has a key
ID, issuer ID, and `.p8` private key. Apple lets the Account Holder request API
access; an Account Holder or Admin can create a team key. Team keys reach every
app, while an individual key inherits one user's app access and role. Apple
allows the private key to be downloaded only once and says never to store it in
source control. [App Store Connect
API](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/),
[Creating API
keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)

This workflow asks Xcode to manage the iOS provisioning profiles, so its Apple
API key must allow that work. Use a tightly held team key for this small
maintainer-only environment. An app-limited individual Developer key cannot use
the provisioning API; do not switch to one unless the workflow also installs
explicit iOS profiles and uses manual signing. If CI later manages external
groups and review, it also needs App Manager access.

The workflow jobs:

- Run the same tests and production preflight as the manual path.
- Archive with `xcodebuild archive`.
- Export with method `app-store-connect`, destination `upload`, symbol upload
  on, and Xcode build-number management off.
- Authenticate with the API key from a temporary secret file.
- Delete temporary key, certificate, profile, archive export, and derived data
  when the job ends.
- Print only version, build, commit, upload state, and safe artifact paths.

Xcode Cloud is a valid Apple-hosted alternative, but it still needs the same app
record, identifiers, capabilities, production CloudKit schema, metadata, and
tester groups. [Distribute Xcode Cloud builds through
TestFlight](https://developer.apple.com/documentation/xcode/distributing-your-xcode-cloud-builds-through-testflight)
