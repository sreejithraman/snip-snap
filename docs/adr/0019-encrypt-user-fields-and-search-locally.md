# 0019: Encrypt user fields and search locally

Snip Snap will use CloudKit encrypted values for every user-derived record field from the first production schema. This includes snip text, source details, list names, filenames, file details, hashes, and sort positions. Attachment bytes will use encrypted `CKAsset` storage. Only random routing IDs, record kinds, schema and protocol versions, required state flags, and sync controls will use ordinary fields. Search, filtering, and sorting will run against the local SwiftData store rather than query CloudKit content.

## Consequences

Record names must use random IDs and must not contain meaningful user data. The app cannot use server indexes or sorting for encrypted fields, which the local store does not need. CloudKit cannot change an ordinary production field into an encrypted field later, so the first production schema must get this boundary right. The app will state that Apple encrypts synced data in transit and on its servers. It will claim end-to-end encryption only when the user's Advanced Data Protection setting supplies it. The release process must check the final build before making an App Store privacy-label claim.
