---
status: superseded by ADR-0012
---

# 0001: Keep a local JSON store with an explicit schema version

## Context

Snip Snap must keep captured text across restarts without an account, network call, or hidden data loss. A damaged store must not look writable when later work cannot persist.

## Decision

Save snips and lists in a JSON document with an explicit schema version at `~/Library/Application Support/Snip Snap/snips.json`. Replace the file as one write. Before recovery from damaged JSON, keep the old bytes in a unique backup. Stop writes if Snip Snap cannot make the backup or new store.

## Consequences

The file location and current schema version are part of the app's data contract. The version makes the shape explicit; it does not promise an upgrade path. During development, a schema change may break the old shape instead of adding upgrade code. Recovery may block new saves, but it will not claim to save work in a short-lived store.
