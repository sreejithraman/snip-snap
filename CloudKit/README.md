# CloudKit schema

`SnipSnap.ckdb` defines the clean schema expected by the current Snip Snap
runtime. It lists only live record types and fields. CloudKit creates each
user's custom zones at runtime, so this file must not name a user's metadata or
payload zone.

Treat this file as a fresh-container baseline, not a destructive diff for an
existing container. For an additive rollout, export the existing Development
schema, add the new fields from this baseline, validate, and import that merged
schema. Deployed retired fields can remain physically present even though the
runtime no longer writes them; do not try to remove them by importing this
clean baseline.

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

## Opt-in Production release preflight

The account-free codec/schema tests prove the baseline matches current codecs;
only a fresh Production export can detect deployment drift. Maintainers can run
this read-only check before publishing a beta:

```sh
# Authenticate once; paste a management token at the secure prompt.
# The token stays outside the checkout in the local macOS Keychain.
xcrun cktool save-token --type management --method keychain

# Set these to the team and container used by the signed release.
export SNIP_SNAP_CLOUDKIT_PREFLIGHT_TEAM_ID='EXAMPLE_TEAM'
export SNIP_SNAP_CLOUDKIT_PREFLIGHT_CONTAINER_ID='iCloud.org.example.snipsnap'
./scripts/cloudkit-release-preflight.sh
```

For file-based authentication, `cktool save-token --type management --method file`
stores the token in local `~/.config/cktool`, outside tracked repository state.
Never put tokens in tracked files, shell command arguments, or release reports.
The command and authentication options follow [Apple's cktool guide](https://developer.apple.com/icloud/ck-tool/)
and the installed tool's `--help`.

Set `SNIP_SNAP_CLOUDKIT_PREFLIGHT_ENABLED=YES` in the maintainer release shell to
make `scripts/publish-beta.sh` and `scripts/testflight.sh upload` fail before
publishing when this check fails. The TestFlight hook uses the resolved release
team and container after validating the archive and matching its runtime
`Info.plist` container; the Mac publishing hook verifies the exact release ZIP’s
signature and Production provisioning profile and reads its signed team and
container, requiring the signed runtime `Info.plist` container to match.
Any explicit target overrides must match that signed artifact.
Use `--mac-release-zip PATH` to perform the same bound check standalone.
The extracted app is inspected without being launched. In protected automation, provision cktool authentication only
in the maintainer release job and set the same environment variables there.
The default is disabled; normal clean-checkout builds and tests never contact
CloudKit or require a maintainer account. Archive and validate commands remain
account-free with respect to this additional check.

Each invocation reruns `CloudKitSchemaContractTests` and requires its expected
test to pass (empty, unmatched, and skipped runs fail), exports **Production**
with `cktool export-schema`, and compares every live field's name, type, and
`ENCRYPTED` storage class. Missing record types/fields and incompatible fields
produce a nonzero exit and a report such as:

```text
CloudKit preflight: missing field List.colorPreset (expected ENCRYPTED BYTES)
```

Extra deployed record types and retired fields (including legacy `List.color`)
are allowed and retained. Export system fields, indexes, and grants are parsed
but are not part of this compatibility check. Malformed or unsupported exports
fail closed. `ASSET` remains an asset field; its CloudKit encryption is not an
`ENCRYPTED` schema modifier.

Reports, the fresh export, and codec test/export logs are saved under ignored
`artifacts/cloudkit-preflight/<unique-run>/`. They include the time, commit,
target, baseline checksum, and result. Set
`SNIP_SNAP_CLOUDKIT_PREFLIGHT_REPORT_DIR` to use another local, untracked report
root. An offline comparison is available with
`ruby scripts/cloudkit-schema.rb CloudKit/SnipSnap.ckdb /path/to/export.ckdb`;
that does not prove the export is current and cannot replace the live preflight.

The preflight never imports, resets, or deploys schema. When it reports missing
fields, review an additive rollout separately, preserve retired fields, and
review the **entire** pending Development-to-Production change set before manual
promotion. Do not deploy unrelated changes merely to make a release gate pass.
Rerun the live preflight after promotion. This checks deployed schema
compatibility; it does not exercise account sync, delivery, or receipt recovery.
