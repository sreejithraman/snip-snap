# TestFlight setup for Snip Snap

Checked against Apple documentation on August 30, 2026.

## Recommended path

Use one iOS-only App Store Connect record for the production iPhone and iPad
app. Keep the current macOS app on its direct-download release path. Protected
CI archives, checks, and uploads each beta; see
[Protected beta delivery](#protected-beta-delivery).

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

Use Xcode's automatic signing for local work on both the iOS app and Share
extension. Select the same paid team for both targets. Protected CI installs
explicit development and App Store Connect profiles for each target, so it does
not depend on a signed-in Xcode account or profile downloads during a build.

Each profile must match its explicit App ID, certificate, and allowed
capabilities. Enabling or changing an App ID capability invalidates old
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

## App diagnostics

Local diagnostic recording is enabled by default in Dev, TestFlight, and Release
builds. The app keeps the newest complete events within a 256 KiB log in its
Application Support directory, excluded from backup. Test runners can use an
explicit isolated diagnostics directory. On iOS the Share extension uses its
own log and shares the recording preference with the app. If the shared
preference is unavailable, events go to the unified log only. Use the unified log
to inspect extension events. The app’s report covers its own history.

On iPhone or iPad, open **Settings → Support → Diagnostics → Share diagnostic
log**. On Mac, open **Settings → iCloud → Support → Share diagnostic log**.
Choose the last 24 hours or seven days of retained history, save the text file,
and attach it to your support message. Export reads local evidence without
fetching from iCloud. Reports include app version and build, timestamps, fixed
operation and outcome codes, stable error codes, and typed sync observations
such as pending counts and phase. Events exclude snip content, filenames, file
paths, account identifiers, and CloudKit record IDs. Recording and export send
nothing automatically.

Turn off **Record local diagnostics** to stop adding events to the local log.
Use **Clear diagnostic log** to discard retained app history. Copies already
saved or shared remain at their destinations.

Apple’s unified log carries structured events under subsystem `SnipSnap`, with
`Operations` for app events and `Runtime` for lifecycle and execution-time
traces. Use Console with the connected iPhone or a system-log archive and filter
by subsystem and category. The unified log has its own retention and is outside
the app’s export and clear controls.

### Investigate an iOS TestFlight issue

For a sync failure or error dialog, ask the tester for the approximate time,
time zone, build number, and steps. In Snip Snap, choose **Settings → Support →
Diagnostics → Last 7 days → Share diagnostic log**. Save or send the text file
through the agreed support channel. For a two-device sync issue, collect a report
from each device. Export before clearing history or deleting the app.

Share this text file separately from TestFlight feedback. TestFlight's documented
feedback downloads contain screenshots or crash reports and comments; they do
not automatically include Snip Snap's custom diagnostic export. A handled sync
error may leave the app running and produce no crash report. [Apple feedback
guide](https://developer.apple.com/help/app-store-connect/test-a-beta-version/view-tester-feedback).

TestFlight also collects crash reports. Keep the distributed archive and its
matching app and share-extension dSYMs so a crash stack can identify the code
involved. Rebuilding the source does not replace that build's matching symbols.
If the app cannot open, use Apple's crash-report channel and preserve the
installation until a repair build can recover its local history. [Apple crash
collection](https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs),
[symbolication](https://developer.apple.com/documentation/xcode/adding-identifiable-symbol-names-to-a-crash-report).

Agents can read the exported text attachment. The Mac `snipsnap diagnostics logs`
command reads logs on that Mac; it cannot retrieve an iPhone's private app data.
Use the selected range and event timestamps to assess the report’s coverage.
Correlate its timestamps and build with any Apple crash report. Events can be
evicted by the byte cap or lost if the app stops before writing them.
Authorized maintainers can retrieve submitted TestFlight crash feedback through
App Store Connect or the optional `asc` tool:

```sh
asc testflight crashes list --app APP_ID --build-id BUILD_ID --sort -createdDate --limit 10
asc testflight crashes log --submission-id SUBMISSION_ID
```

Use existing approved App Store Connect credentials and keep retrieved reports
in ignored incident files. These tools and credentials are not required for
contributor builds or local diagnostic exports. The feedback list covers
submitted feedback; do not treat an empty result as proof that no crash occurred.
[Apple crash-feedback interface](https://developer.apple.com/documentation/appstoreconnectapi/betafeedbackcrashsubmission).

## Protected beta delivery

`.github/workflows/beta-candidate.yml` tests each release-sized push to `main`.
A newer push cancels an older candidate that is still testing. After a candidate
passes, `.github/workflows/beta.yml` checks that its commit is on `main` and
that no later commit changed the watched release inputs, then uses the protected
`apple-release` environment for signed work. The delivery workflow runs one
release at a time, never cancels a release that has started, and keeps waiting
runs queued.

The delivery uploads the iOS build to TestFlight and publishes the same-number
Mac beta to GitHub, Sparkle's `beta` channel, and the `snip-snap@beta` cask. Set
the repository environment variable `SNIP_SNAP_BETA_DELIVERY_ENABLED` to `true`
only after all protected inputs have been added. Until then, candidates run the
public checks and protected delivery jobs stay skipped. To start a beta by hand,
dispatch the Beta candidate workflow; delivery cannot bypass its checks.
The release record saves both the candidate and delivery run IDs so stable
promotion can check the unsigned tests and signed jobs for the same commit.

Add these secrets to `apple-release`:

- `APPLE_API_ISSUER_ID`
- `APPLE_API_KEY_ID`
- `APPLE_API_PRIVATE_KEY`
- `APPLE_TEAM_ID`
- `IOS_DISTRIBUTION_CERTIFICATE_BASE64`
- `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`
- `IOS_DEVELOPMENT_CERTIFICATE_BASE64`
- `IOS_DEVELOPMENT_CERTIFICATE_PASSWORD`
- `IOS_APP_DEVELOPMENT_PROFILE_BASE64`
- `IOS_SHARE_DEVELOPMENT_PROFILE_BASE64`
- `IOS_APP_STORE_PROFILE_BASE64`
- `IOS_SHARE_APP_STORE_PROFILE_BASE64`
- `IOS_APP_STORE_PROFILE_NAME`
- `IOS_SHARE_APP_STORE_PROFILE_NAME`
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

The workflow installs explicit iOS profiles before it builds. The API key is
used for App Store Connect upload, not for creating or downloading profiles.
Renew the protected profiles when their certificate expires or an App ID
capability changes.

Xcode uses Apple Development signing and the installed development profiles for
the archive. It then uses Apple Distribution signing and the two named App Store
Connect profiles during export. Keep both iOS identities and all four profiles
in the protected environment. The archive check accepts either push
environment; the uploaded export uses production distribution profiles.

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
