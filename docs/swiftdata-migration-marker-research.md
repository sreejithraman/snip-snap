# SwiftData migration marker research

Launch no longer reads `migration.json`. The Mac app opens the SwiftData store directly. This note is the earlier marker design.

Date: September 2, 2026

## Result

Use `migration.json` to check app-owned facts, such as the marker format and store path. Let SwiftData read and update its own store schema. An old marker version that appears in the declared migration plan must not stop the store from opening.

For the current code, accept marker `schemaVersion` values `1...4`, then create the `ModelContainer` with schema V4 and `SnipSnapSchemaMigrationPlan`. Update the marker to V4 only after that call succeeds. Reject bad markers, unknown marker formats, and versions above V4 before opening the store. If the container or a later check fails, keep the final store where it is and do not open the old JSON store for writes.

Apple says `ModelContainer` manages the store and moves saved model data to a new schema when needed. Apple defines `SchemaMigrationPlan` as the list of known schemas and the steps between them. Its sample gives that plan to the container. The container open, not the marker, must run the schema change. [ModelContainer](https://developer.apple.com/documentation/swiftdata/modelcontainer), [SchemaMigrationPlan](https://developer.apple.com/documentation/swiftdata/schemamigrationplan), [Model your schema with SwiftData](https://developer.apple.com/videos/play/wwdc2023/10195/)

## Start-up order

1. Check that the final `Local` folder, store file, and marker have the expected form.
2. Decode the marker. Require a known marker `version`, and keep the current path and file-name checks.
3. Check `schemaVersion`:
   - If the migration plan names the version, continue. The current plan names `1...4`.
   - If the version exceeds `currentVersion`, stop before opening. This app cannot change a newer schema to an older one.
   - If the version is zero, negative, missing, or bad, stop before opening.
4. Create `ModelContainer` with the current `VersionedSchema`, the full `SchemaMigrationPlan`, and the final store URL. A successful call means SwiftData opened or updated the store. An error means the app must not report success. [ModelContainer initializer](https://developer.apple.com/documentation/swiftdata/modelcontainer/init%28for%3Amigrationplan%3Aconfigurations%3A%29-1czix), [MigrationStage](https://developer.apple.com/documentation/swiftdata/migrationstage)
5. Run any app checks that must pass before writes begin.
6. If the marker records the last schema opened by the app, replace it with `schemaVersion == currentVersion` now. Keep the import facts, including `sourceVersion`, source and backup paths, and `completedAt`. Use an atomic write so readers see either the old marker or the new one. Apple's atomic data-write option writes a new file first, then replaces the old file. [Atomic writes](https://developer.apple.com/documentation/foundation/nsdata/writingoptions/atomic)
7. Return the writable library only after all checks finish.

Do not update the marker before creating the container. That could record a schema change that did not finish.

## Clearer marker fields

The current `schemaVersion` field records both the schema the first JSON import used and the latest schema the app opened. A later marker format should split those facts:

- `importedWithSchemaVersion`: the schema the JSON import used; never change it.
- `lastOpenedSchemaVersion`: the latest schema this app opened; use it to stop an older app from opening a newer store.

This split keeps the import record true and lets an older app reject a store that a newer app opened. SwiftData must still read the store schema and choose the migration steps.

For this fix, keep the existing field, treat it as `lastOpenedSchemaVersion`, and accept old versions the plan names. Let SwiftData update the store, then update the marker.

## Failure rules

- For a missing or bad marker, wrong marker format, unsafe path, or wrong store name, do not change the `Local` or JSON stores. The current safety path may add a read-only backup of the JSON data.
- For a marker version newer than this build, stop before creating `ModelContainer`.
- If the marker holds a supported old version but the container fails, keep the old marker and the store where they are. Return a library that cannot write.
- If the container succeeds but the marker write reports an error, return a library that cannot write for this launch. An error after the atomic replacement may leave either the old or new valid marker on disk. A later launch can safely try again or open the current store.
- Never open the old JSON store for writes after the final SwiftData folder exists. That would let the two stores record different edits.

These rules match the repo's choice that only the main app opens and updates the SwiftData store. They also keep a final store in place when its marker fails a check. [ADR 0016](adr/0016-use-swiftdata-with-cksyncengine.md), [platform review](apple-platform-conventions-2026.md)

## Repo check

The repo declares V1, V2, V3, and V4 in order, with a small step between each pair, in [`SwiftDataStoreSchema.swift`](../Packages/SnipSnapLibrary/Sources/SnipSnapPersistence/SwiftDataStoreSchema.swift). `SwiftDataSnipLibrary` creates a V4 container with that plan in [`SwiftDataSnipLibrary.swift`](../Packages/SnipSnapLibrary/Sources/SnipSnapPersistence/SwiftDataSnipLibrary.swift). A test already creates a V1 store and opens it through the current library. This proves that V1 can reach V4 with the installed tools. The old start-up check blocks that path because [`MacLocalSnipLibraryBootstrap.swift`](../Packages/SnipSnapLibrary/Sources/SnipSnapPersistence/MacLocalSnipLibraryBootstrap.swift) used to require the marker version to equal V4 before it called the library factory.

Add focused start-up tests for:

- each supported old marker version;
- a current marker;
- a future, zero, negative, missing, and bad schema version;
- a container failure that leaves the marker unchanged;
- marker-write errors before and after atomic replacement;
- a successful old-marker open that updates the marker.

## Source limits

Apple does not document this app's marker because Snip Snap owns that file. The marker rules above follow from the split in file ownership: SwiftData handles its store schema through `ModelContainer` and `SchemaMigrationPlan`; Snip Snap checks its import record and start-up rules. The installed macOS 26.5 SwiftData interface also shows that the model-container initializer takes an optional migration-plan type and can throw, which matches Apple's public docs.
