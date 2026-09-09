# iOS haptic policy

Actions report an outcome to `IOSHapticFeedback`. Its `Kind.meaning` groups those outcomes, and `IOSSystemHapticPlayer` maps each meaning to one system response. Tune a meaning in that adapter; keep strength choices out of views and action handlers.

| Meaning | System response | Current outcomes |
| --- | --- | --- |
| Selection changed | Selection tick | Explicit snip selection |
| Gesture committed | Medium impact | Pull-to-create snap |
| Action completed | Light impact | Save, copy, mark done, reopen, delete, restore, move |
| Significant success | Success notification | Merge |
| Attention | Warning or error notification | Unavailable action or failure |

These mappings are app design choices. Apple recommends consistent meanings, clear causes, and feedback that agrees with the visible action; Apple does not prescribe these exact mappings or promise a fixed physical strength across devices. See [Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics).

## Event rules

- Keep one owner for each event. Native controls retain their own system feedback.
- Emit completion only after the action succeeds. Unchanged results stay quiet.
- Emit the create snap once when the plus reaches full reveal. Cancelling its sheet adds no feedback.
- Keep ordinary navigation, scrolling, and screen opening quiet.
- A compound result makes one request: error wins over warning, then the last outcome wins.
- Honor the haptics preference, scene state, task cancellation, and interaction token. Old work must not emit after the user starts another interaction or leaves the flow.
- Keep visible and accessible confirmation when haptics are off. Reduce Motion uses the same committed state without waiting for an animation.

Heavy and rigid impacts are outside the default set. Add a new meaning only when an existing meaning cannot describe the event.

## Verification

`IOSHapticFeedbackTests` checks outcome grouping, action results, repeated actions, no-ops, failure precedence, preferences, and stale work. `testSelectorPullThresholdCancelAndCreate` checks below-threshold return, one create snap, cancellation, and repeated creation. These checks prove requests and timing; judge physical feel on an iPhone.

Verified on September 8, 2026: all 19 haptic tests and the selector pull/cancel/create UI test passed on the Dev 6 iOS 26.5 Simulator. `scripts/run.sh` built, installed, and opened Dev 6 on the connected iPhone 17 Pro. Physical feel remains for user review.
