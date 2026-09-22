# 0029: Store iCloud attachment downloads in cache directories

Snip Snap stores re-downloadable iCloud attachment bytes under the iOS app
group's `Library/Caches` directory and the macOS user cache directory. Each
sync-mode store and sync generation keeps a separate subtree. SwiftData cache
rows remain the source of identity, size, hash, and least-recently-used state;
a missing file is a cache miss and never removes the accepted attachment
metadata.

Existing downloads beside the store remain readable after upgrade. The first
cache sweep verifies each legacy file, copies it durably into the cache
directory, and only then removes the old copy. A failed copy leaves the legacy
file and row intact. Cache clearing, sync-cache retirement, and orphan cleanup
cover both locations.

The cache resolver trusts the app-owned namespace root even when iOS exposes
that root through a container alias. It still rejects malformed relative paths
and every symlink below the root. Install, read, touch, eviction, invalidation,
sweep, and cleanup share this resolver. Namespace and store retirement follow
trusted namespace-root aliases so they remove the cache bytes rather than only
the alias. Upload and import roots keep their stricter root validation.

Before leaving iCloud sync, Snip Snap re-downloads any cache misses and promotes
each attachment into durable local storage before the mode transition starts.
If bytes cannot be recovered, the transition stops and keeps the cloud metadata
and source store. Account-isolation quarantine follows the same fail-safe rule
when the prior account is unavailable.

The cache module owns receipt validation, staged-file validation, installation,
database commit, rollback, and safe staging cleanup behind one operation. The
CloudKit coordinator owns the fetch and reports its diagnostics, but does not
reimplement the local file transaction or its trust rules.

User-added attachment bytes and queued upload bytes stay in durable app support
storage. They are not re-downloadable caches. Cache files remain excluded from
backup even though `Library/Caches` is excluded by convention, because file
moves can reset that resource value.
