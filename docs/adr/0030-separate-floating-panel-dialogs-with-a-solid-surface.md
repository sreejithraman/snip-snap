# 0030: Separate floating panel dialogs with a solid surface and shadow

## Context

The Mac panel has a transparent window frame around its floating surfaces. A native sheet adds a dim layer over the full parent window rectangle. The desktop then darkens inside that rectangle, exposing the invisible frame whenever an app-owned form or confirmation appears. This replaces the accepted sheet-dimmer tradeoff in ADR 0008.

Reducing the parent to 45% opacity avoided the rectangular dim layer, but made its content appear faded and exposed unrelated windows underneath. The user requested separation through a shadow instead. This decision replaces that opacity treatment and the nested-glass dialog surface from ADR 0008.

## Decision

Present app-owned forms, confirmations, and error dialogs in a borderless child window centered over the panel. Give the dialog an opaque system window background in the parent's selected appearance and a native macOS shadow. Keep the parent's existing opacity throughout presentation and dismissal. Disable and hide the parent content from accessibility while the dialog is open. Block parent key focus and file drops while any dialog or file picker is presented, returning clicks on exposed parent chrome to the active modal window. Keep the dialog key, follow parent moves and resizes, restore the parent's focus on dismissal, and dismiss it when the parent hides. A nested alert may still use a native sheet on the dialog itself. Present file import and export with standalone system panels in the selected app appearance, positioned beside the parent when space allows and kept on its screen. File pickers retain their separate parent-dimming treatment. If the picker would overlap the panel, hide the parent until the picker closes.

## Consequences

The desktop stays continuous around the floating panel in light and dark appearances. The dialog's solid surface and shadow provide separation while the panel stays readable at its usual opacity. Dialog ownership, queuing, keyboard shortcuts, and error presentation must be maintained by the panel coordinator because AppKit no longer supplies those behaviors through a sheet. Tests cover child ownership, focus, preserved parent opacity, queuing, and movement; real-app screenshots cover the solid dialog surface, shadow, and button legibility.
