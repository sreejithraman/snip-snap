# 0017: Use CloudKit deletions with local recovery

Snip Snap will delete CloudKit records normally instead of keeping permanent app-owned tombstone records. It will retain a local outbound-delete ledger until CloudKit acknowledges each deletion, save the last known server fields for synced records, and fetch the remote collection before sending after a new bootstrap or lost sync state. If a stale offline edit receives `unknownItem`, the original stays deleted and the edit becomes a recovered snip with a new identity.

## Consequences

The adapter must treat the remote collection as authoritative during bootstrap and must not rebuild stale records as new records with their old identities. SwiftData History must retain each deleted record's stable CloudKit ID until the sync consumer advances. Durable fake-client tests must cover state loss and both orders of delete versus offline edit on Mac and Simulator.
