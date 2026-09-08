# 0026: Preserve pinned clipboard content

Pinned clipboard entries remain clipboard entries and survive history trimming and Clear History. Pinning a file entry will preserve an app-owned copy so removing the source file does not break the pin. This extends the clipboard lifetime described in ADR 0006 without converting a pinned entry into a saved snip.

If the source file is missing or unreadable, leave the entry unpinned and explain why. If the local copy succeeds but upload fails, keep the entry pinned and offer Retry.
