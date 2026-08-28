# 0022: Require iOS and iPadOS 26

Snip Snap will add iPhone and iPad apps that require iOS and iPadOS 26. The app and its tests will use version 26 SwiftUI controls directly and will not add older UI or test paths. ADR 0004 remains the separate macOS 26 decision.

## Consequences

The iOS app has one UI generation to maintain. Snip Snap will not run on older iPhone or iPad system versions. Lowering either target later requires a separate change with replacement controls and parity checks.
