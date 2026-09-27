# Configuration-preserving datastore cutover

The replacement uses `OverplayLibraryV2.store` and six new persistent entity
names. Source-level `TrackRecord`, `PlaylistRecord`, etc. are aliases to the V2
models. The old `default.store` and old CloudKit record types are not migrated or
deleted. This is a pre-release cutover, not a released-data migration framework.

## Export before launching the replacement

Stop the old app. Read its database using the read-only exporter:

```sh
python3 Diagnostics/DatastoreRebuild/export_configuration.py \
  --store '/path/to/Application Support/default.store' \
  --output '/private/tmp/overplay-library-configuration-v2.json'
```

The export contains only active remote playlist references, names, roles, write
permissions and display order. It validates exactly one Overplay playlist and
unique source IDs. It writes a new file exclusively with mode 0600 and verifies
its decoded contents. It neither exports track state nor writes to SQLite.

After build/test validation, place the verified export at the application's
Documents/overplay-library-rebuild-v2.json. On authorized startup the app resolves
all configured sources, commits the replacement graph and receipt together, and
then starts ordinary services. A source failure displays a retryable error and
publishes no partial graph. A completed receipt skips the file on subsequent
launches. A different file cannot overwrite a populated replacement store.

After live validation, rename the input to
`Documents/overplay-library-rebuild-v2.completed.json`. Keep that verified archive
and the legacy store for recovery. Removing the pending input by renaming it also
ensures a later deliberate factory reset does not replay this one-time cutover.
Do not run the old and replacement executables simultaneously. Older builds still
use the old dataset; they do not participate in the replacement dataset. Other
devices require the replacement build to use its entity types. Production
CloudKit schema deployment is a separate release step; do not reset CloudKit or
remove old record types as part of this cutover.

## Expected results

- Source link roles/permissions match the verified export.
- One local track and membership per proven identity; Overplay wins import overlap.
- Triage provenance retains every contributing source and source occurrence.
- Overplay skip/playthrough counts and history start empty. First observed Apple
  lifetime counts establish baselines rather than crediting past plays.
- Restart does not import again or recreate duplicates.
- Native playback objects are reconstructed through typed MusicKit endpoints
  after restart and never persisted to CloudKit.
- Subsequent unchanged imports do not write native cache refreshes as metadata.

Unit tests exercise local atomicity, identity domains/scopes, fresh activity,
configuration validation, restart idempotence, native-cache exclusion and failure,
and canonical playlist pagination. Live CloudKit propagation and physical CarPlay
behavior need their own evidence; simulator tests do not establish either.
