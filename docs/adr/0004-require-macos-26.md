# 0004: Require Apple OS 26

## Context

Snip Snap is a small app for one user. Its Mac panel uses macOS 26 Liquid Glass controls, and its iOS app will use the matching generation of SwiftUI controls. The user approved dropping support for older system versions so the project does not need two UI paths.

## Decision

Set the Mac app and tests to macOS 26. Set the iPhone and iPad app and tests to iOS and iPadOS 26. Use the version 26 controls directly and do not add older UI or test paths.

## Consequences

The code has one UI generation to maintain on each platform. Snip Snap will not run on older system versions. Lowering a target later requires a separate change with replacement controls and parity checks.
