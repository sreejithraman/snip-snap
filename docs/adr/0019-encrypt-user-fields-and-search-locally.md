# 0019: Encrypt user fields and search locally

Snip Snap will use CloudKit encrypted values for every user-derived record field from the first production schema. This includes snip text, source details, list names, filenames, file details, hashes, and sort positions. Attachment bytes will use encrypted `CKAsset` storage. Only random routing IDs, record kinds, schema and protocol versions, required state flags, and sync controls will use ordinary fields. Search, filtering, and sorting will run against the local SwiftData store rather than query CloudKit content.

## Consequences

Record names must use random IDs and must not contain meaningful user data. The app cannot use server indexes or sorting for encrypted fields, which the local store does not need. CloudKit cannot change an ordinary production field into an encrypted field later, so the first production schema must get this boundary right.

Synced records live in the user's private iCloud database. Snip Snap's maintainers cannot inspect private records in CloudKit Console. Apple encrypts synced data in transit and at rest. Snip Snap stores user fields as CloudKit encrypted values and file bytes as `CKAsset` data. The app must say that synced data is end-to-end encrypted only when Advanced Data Protection is on for the user's iCloud account. The release process must check the final build before making an App Store privacy-label claim.
