# 0004: Require macOS 26

## Context

Snip Snap is a small app for one user. Its panel uses macOS 26 Liquid Glass controls. The user approved dropping support for older macOS versions so the app does not need two UI paths.

## Decision

Set the app and test targets to macOS 26. Use the macOS 26 controls directly and remove older UI and test paths.

## Consequences

The code has one panel layout and one set of focus and access behavior to maintain. Snip Snap will not run on older macOS versions. Lowering the target later requires a separate migration with replacement controls and parity checks.
