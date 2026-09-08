# 0027: Use pins for reusable content

Both saved snips and clipboard entries can be pinned. Pins stay at the top of their own list or clipboard history, newest pin first; there is no separate Pinned view. Copying a pin does not change its pin order.

A pinned snip cannot be Done. Pinning a Done snip makes it Not Done, and unpinning leaves it Not Done. Pinned snips show Copy instead of the completion control wherever they appear. This makes pinning a choice to keep content for reuse and avoids showing completion actions that contradict that choice. Apply this rule in shared data operations, including sync and bulk actions, as well as the UI.
