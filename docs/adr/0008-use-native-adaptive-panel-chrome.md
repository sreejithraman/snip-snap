# 0008: Use native adaptive panel chrome

## Context

Snip Snap floats over other apps, so its chrome must remain clear over backgrounds it does not control. Fixed white or black fills, custom blur plates, and outer glow layers fought macOS appearance and accessibility settings. Several one-off glass recipes also made similar controls look unrelated.

## Decision

Use macOS 26 Liquid Glass for top-level panel controls and navigation. Put nearby custom glass in a shared `GlassEffectContainer` when they form one visual group. Use named semantic color roles for text, state, edges, cards, and actions. Let native glass adapt to its backdrop and the selected System, Light, or Dark appearance. Do not force glass to a light or dark tint, add a window-wide blur plate, or draw a custom halo. Keep content cards as a separate content surface.

Keep custom panel resizing on AppKit's native event path. One border view owns eight edge and corner `NSTrackingArea` regions, reads cursor identity from the generating area, and uses the system frame-resize cursors. AppKit owns idle hover. Snip Snap only takes cursor ownership for an active resize and always restores it when the resize ends.

## Consequences

Small and large glass surfaces can resolve to different tones over the same background. That native response is expected. Tints remain reserved for meaning or emphasis. Reduce Transparency, Increase Contrast, and Reduce Motion continue to work through the system. New views should reuse the shared surface and color roles instead of adding raw colors or opacity recipes.

The borderless panel needs a small AppKit resize view, but it does not need app-wide mouse monitoring, manual hover state, or legacy cursor rectangles.
