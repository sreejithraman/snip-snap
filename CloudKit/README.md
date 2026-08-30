# CloudKit schema

`SnipSnap.ckdb` defines the Development schema used by Snip Snap. It lists only
record types and fields. CloudKit creates each user's custom zones at runtime,
so this file must not name a user's metadata or payload zone.

The schema has five record types:

- `Snip` and `List` keep opaque IDs and the schema version in ordinary fields.
  All user data uses encrypted fields.
- `AttachmentMetadata` keeps only the schema version in an ordinary field. All
  names, sizes, hashes, links, and other metadata use encrypted fields.
- `AttachmentPayload` keeps its schema version in an ordinary field and its
  file in an `ASSET` field. CloudKit encrypts `CKAsset` data by default and the
  schema language has no `ENCRYPTED ASSET` form.
- `SnipSnapCollectionControl` holds only opaque generation and zone routing
  data. It has no user content.

No field has a query, sort, or search index. Package tests compare this file
with records made by every live codec and fail if either side adds, removes, or
changes a field or its storage class.

Snip, List, attachment metadata, and collection-control codecs accept a higher
schema version when all fields they need remain valid. An edit keeps that
higher version and any unknown fields. Attachment payload records are
immutable: changed file bytes use a new opaque record ID instead of updating an
accepted payload record.

Maintainers can export or import the Development schema with `cktool` and
ignored local credentials. Normal builds and tests do not need an Apple team,
CloudKit credentials, a signed app, or access to the production container.
Review this file before promotion: CloudKit does not let a production ordinary
field become encrypted later.
