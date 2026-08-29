# Accessibility permission onboarding research

Date: 2026-08-29

This note compares the main ways Snip Snap can ask for macOS Accessibility access. It uses Apple docs and source repos as sources.

## Short answer

Keep this flow in Snip Snap for now. Use Apple's native prompt after a short Snip Snap note, check access again when the app comes to the front, and add a status row in Settings for later repair.

Do not add PermissionFlow in the first pass. It gives strong drag-and-drop help, but Snip Snap needs one permission and already owns the two key calls. The package would add exact System Settings links, window tracking, more permission code, a license notice, and a fast-moving release to watch. Add it later only if tests show that users often fail to finish Apple's flow.

## What Snip Snap has now

`AppCoordinator` already uses Apple's public calls:

- `AXIsProcessTrusted()` checks current access.
- `AXIsProcessTrustedWithOptions` with `kAXTrustedCheckOptionPrompt` asks macOS to inform the user.

Apple says the prompt runs at once in the background and does not change the call's return value. The call returns only `true` or `false`, so it cannot tell “not asked” from “denied.” Snip Snap should keep `granted` and `notGranted` as the system states. It may save `requestAttempted` only as a UI hint; Apple's access check still decides whether access is on. [`AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)

Apple's macOS 26 guide says the system alert can take the user to System Settings. The user then turns on the app. If the app does not appear, the user can add it with the Add button. Apple does not list drag-and-drop as part of this flow. [Allow accessibility apps to access your Mac](https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac)

The current app explains the need before it calls Apple. It asks at app start, has no lasting status row, and does not update the shown state when the user comes back from System Settings.

## Options

| Choice | User flow | Code and upkeep | Risk | Fit for Snip Snap |
| --- | --- | --- | --- | --- |
| Apple prompt only | Snip Snap explains, then macOS shows its alert and opens Settings | Very small; Apple owns the alert | Lowest; public API only | Good base, but gives little help when access stays off |
| Snip Snap guide plus Apple prompt | Add a clear reason, live status, repair steps, and a Settings row around the Apple call | Small and easy to test | Low; an exact Settings link needs a fallback | Best choice |
| PermissionFlow | Open the right pane and show a floating app card that the user can drag into it | Package handles the panel, drag source, pane links, and window tracking | More OS layout and package churn | Useful only if tests show the base flow fails often |
| PermissionPilot | Use a full permission wizard with many status checks and restart paths | Much broader package and UI | Very new; more code than this app needs | Poor fit for one permission |

## Recommended Snip Snap flow

1. Do not ask on every app start. Ask when the user first turns on a Shift shortcut, first uses selection capture, or chooses to finish setup. If the product treats these features as required, show one setup step after the app has said what the access enables.
2. Show a Snip Snap sheet first. State that access lets Snip Snap detect its Shift shortcuts and read selected content. State that the user can turn access off later.
3. On Continue, call `AXIsProcessTrustedWithOptions` once with the prompt option. Do not poll with the prompt option.
4. Use `AXIsProcessTrusted()` without a prompt when Snip Snap becomes active and before each protected action.
5. Add a Settings row with `Accessibility: On` or `Accessibility: Off`, `Open System Settings`, and `Check Again`.
6. If access stays off, show Apple's manual path: System Settings → Privacy & Security → Accessibility → turn on Snip Snap. Also say to use Add if Snip Snap is missing.
7. Let the rest of the app work when access stays off. Disable only the actions that need it, and keep their repair action close at hand.

For `Open System Settings`, first try the exact privacy pane link. `NSWorkspace.open(_:)` is public, but Apple does not document the `x-apple.systempreferences:` privacy anchors that the packages use. If the exact link fails, open the System Settings app and keep the manual steps on screen. [`NSWorkspace`](https://developer.apple.com/documentation/appkit/nsworkspace), [PermissionFlow's link format](https://github.com/jaywcjlove/PermissionFlow/blob/main/Sources/SystemSettingsKit/SystemSettingsDestination.swift)

This design uses Apple's access check and puts all app text, timing, and status in a small Snip Snap-owned service. Tests can replace the trust check, request, app activation notice, and Settings launch.

## PermissionFlow review

PermissionFlow 2.11.2 supports macOS 13 and later, uses Swift 6.2, and has no outside package dependencies. Its MIT license permits use and changes but requires its copyright and license text in copies of the software. Snip Snap's macOS 26 target meets the package floor. [`Package.swift`](https://github.com/jaywcjlove/PermissionFlow/blob/main/Package.swift), [MIT license](https://github.com/jaywcjlove/PermissionFlow/blob/main/LICENSE)

The Accessibility path calls public AppKit, Core Graphics, and Accessibility APIs. It checks status with `AXIsProcessTrusted()`. Its controller opens an `x-apple.systempreferences:` URL, shows a panel, polls the Window Server at 30 Hz, and adds AX observers after the app gains trust. This means the package uses a fallback while it guides the user to grant the same access that improves its tracking. [Controller](https://github.com/jaywcjlove/PermissionFlow/blob/main/Sources/PermissionFlow/PermissionFlowController.swift), [window tracker](https://github.com/jaywcjlove/PermissionFlow/blob/main/Sources/PermissionFlow/Tracking/SettingsWindowTracker.swift), [status provider](https://github.com/jaywcjlove/PermissionFlow/blob/main/Sources/PermissionFlow/PermissionStatusProviders/AccessibilityPermissionStatusProvider.swift)

The package's source calls only documented framework functions in this path, but the privacy pane URL and its anchor names are not part of Apple's docs. The package also has to choose and align with the right System Settings window. Both parts can change with macOS. Its current open issues include panel placement and status refresh. [Open issues](https://github.com/jaywcjlove/PermissionFlow/issues)

The project began on 2026-04-17 and shipped 18 tags through 2.11.2 on 2026-08-16. That shows active work, but it also makes an exact version pin and upgrade checks important. [Releases](https://github.com/jaywcjlove/PermissionFlow/releases)

The core module also contains status code for permissions that Snip Snap does not use, including a Full Disk Access file probe. Linking it adds more review scope than the Accessibility flow needs. [Full Disk Access provider](https://github.com/jaywcjlove/PermissionFlow/blob/main/Sources/PermissionFlow/PermissionStatusProviders/FullDiskAccessPermissionStatusProvider.swift)

If later tests justify PermissionFlow:

- Keep Snip Snap's permission service and status model.
- Link only the `PermissionFlow` product.
- Pin one exact tag, starting with the tested current tag rather than a range.
- Set `promptForAccessibilityTrust` to `false`; Snip Snap should own the Apple prompt.
- Add the MIT notice.
- Test the release app on macOS 26 with one and two screens, moved and resized System Settings windows, a missing app row, denied access, revoked access, and a fresh install.

## Other packages

PermissionPilot offers a full first-run wizard and live checks for many permissions. It supports macOS 12 and uses an MIT license, but it began on 2026-06-20 and has only 0.1.0 and 0.2.0 releases. Its Settings helper tries `NSWorkspace`, `/usr/bin/open`, and AppleScript. These are not private APIs, but they add paths that Snip Snap does not need. [PermissionPilot](https://github.com/arpitagarwal1301/PermissionPilot), [Settings link source](https://github.com/arpitagarwal1301/PermissionPilot/blob/main/Sources/PermissionPilotCore/SystemSettingsLink.swift)

MacPaw's older PermissionsKit has more history, but it does not support Accessibility. Its own README also says one part uses a private API. It is not a choice for this task. [MacPaw PermissionsKit](https://github.com/MacPaw/PermissionsKit)

The `macos-accessibility-client` repo is a useful reference app, not a package. It uses the same small design proposed here: Apple prompt, in-app status, an exact Settings link, and a manual check. [macos-accessibility-client](https://github.com/drewster99/macos-accessibility-client)

## Store and release notes

Apple requires Mac App Store apps to use App Sandbox. Snip Snap's selection-capture ADR already says the app must run outside that sandbox, so this product choice blocks a normal Mac App Store build before the onboarding choice enters the question. [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox), [ADR 0002](adr/0002-safe-selection-capture.md)

Developer ID release and notarization remain the right path. Apple says notarization checks signed software for harmful code and signing faults; it is not App Review. Native code and PermissionFlow still need a signed, hardened release build and a real end-to-end check. [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## Decision

Build the small Snip Snap-owned guide first. Do not add a package until user tests show a clear problem that the package fixes. If people fail because Snip Snap does not appear in the list or they cannot find the Add flow, run a short PermissionFlow trial behind the existing service and compare completion rates before making it a release dependency.
