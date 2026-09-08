# 0025: Make clipboard history sync a separate choice

Clipboard history sync will have its own switch under iCloud sync, off by default, and will require iCloud sync to be on. Enabling saved-snips sync alone will leave clipboard history local, so an existing sync choice does not start uploading automatically captured content. This replaces the local-only requirement for clipboard history in ADR 0006; clipboard entries and saved snips will keep their separate models.

With clipboard sync on, Clear History will remove unpinned history across devices and preserve pins. Explicit deletion will remove an entry across devices, including pinned entries. Turning clipboard sync off will stop history uploads and downloads on that device, keep its local history, and leave iCloud data intact.

Sync text, rich text, and images. File references will stay on their source Mac until pinned; pinning will preserve and transfer the actual files. This avoids uploading every file a user copies. Mark those local file entries “Only on this Mac” and explain “Pin to sync this file” when clipboard sync is on. Show upload progress and a retry action after failure.

iOS will support explicit capture through a Paste button in Clipboard and a Clipboard destination in the existing Share extension. Continuous background capture and a custom keyboard are outside this change.

On first enable, explain that existing history will upload, then merge local and iCloud history, remove duplicates, and preserve pins. Keep the latest 100 unpinned entries across devices, subject to the existing size limits. Pins stay outside automatic trimming.

Files shared directly from iOS will get an app-owned copy on receipt. They remain local until pinned, with “Only on this iPhone” or “Only on this iPad” as appropriate.

After a file has synced, unpinning it keeps its shared identity and syncs that change. It becomes subject to normal history trimming. Pinning grants the file upload; unpinning does not withdraw it or delete other devices’ copies.

Local-only file references use their own retention allowance, so they cannot evict another device’s shared history. Automatic trimming and Clear History record cleanup separately from explicit deletion: an offline pin survives cleanup, while explicit deletion still wins over an offline edit.
