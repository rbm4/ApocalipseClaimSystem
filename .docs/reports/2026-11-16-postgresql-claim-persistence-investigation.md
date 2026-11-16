# PostgreSQL claim persistence investigation

Date 2026-11-16, America/Fortaleza.

## Scope and recommendation

This investigation covers the file-backed vehicle database, the authoritative claim registry, the recent PvPTerritory ranking migration, and the ApocalisebrPack entity facade and Java bridge. The deliverable is this report. Runtime Lua, database schema, configuration, and saved claims were left untouched.

The smallest change matching the initial request is an optional PostgreSQL backend for `VehicleClaim_ServerDatabase.lua`. With `APOCALISEBR_PACK` active, route its vehicle metadata and inventory summaries to PostgreSQL. Keep the claim registry in its existing GlobalModData location. With the pack absent, retain the current native/file behavior. This would move the export database and preserve the current claim authority and gameplay workflow.

Moving the claims themselves to PostgreSQL is a larger second option. It also replaces the claim-specific `VehicleClaimRegistry` persistence and requires startup readiness, asynchronous mutation handling, and commit barriers in the server command handlers. That option can cover access lists and abandonment timestamps, which the current export files omit.

For either option, reuse `ApocBR/Entities` and the existing worker. The existing scoped document API is the closest match to the PvPTerritory implementation. A physical dedicated claims table is feasible, with the bridge extensions described below. A mod-wide replacement of every ModData access would also touch vehicle identity and client mirrors, expanding the requested database work.

## Investigated versions and evidence limits

The detailed claim analysis targets `Contents/mods/ApocalipseClaimSystem/42.19`. The repository README identifies this folder as the target of the current registry-authority security changes. Every versioned `mod.info` inspected uses mod ID `VehicleClaimSystem`.

The other packaged folders need independent treatment when implementation is selected.

| Folder | Database implementation observed |
| --- | --- |
| `42.13.1` | No `VehicleClaim_ServerDatabase.lua` at the inspected server path |
| `42.14`, `42.15` | Identical database-file hashes, monolithic JSON save implementation |
| `42.17` | Separate monolithic implementation |
| `42.19` | Indexed per-car export, queue, dirty flags, cooldown and position checks |

The pack facade lives under `ApocalisebrPack/42.14`, with `versionMin=42.13`. Its newest document APIs depend on the patched engine. The bridge source inspected is the patch project's `42.22.2` implementation. Folder compatibility and active mod detection alone cannot establish installed Java/schema compatibility.

This was source inspection with read-only inspection of local export metadata. No server was started, no database connection was opened, no migration was run, and no performance benchmark or regression fixture was executed. The database migration SQL was inspected in the adjacent manager repository. Deployed schema and bridge versions remain unverified.

## Current persistence ownership

### Authoritative claim registry

`VehicleClaim_ServerCommands.lua` obtains `ModData.getOrCreate("VehicleClaimRegistry").claims`. The table is indexed by persistent vehicle hash and owns server authorization, claim counts, player lists, remote release, access changes, contest eligibility, and reconciliation of loaded vehicles.

Each registry record contains the following fields.

| Field | Meaning |
| --- | --- |
| `vehicleHash` | Persistent vehicle identity |
| `ownerSteamID`, `ownerName` | Claim owner identity and display name |
| `x`, `y` | Last-known vehicle coordinates |
| `vehicleName` | Vehicle display name |
| `claimTime` | Claim timestamp in game minutes |
| `lastSeen` | Last-seen timestamp in game minutes |
| `allowedPlayers` | Access map keyed by Steam ID |

The engine's `GlobalModData` implementation persists global tables in the current world's `global_mod_data.bin`. Its `transmit` path handles network transmission. Calling `ModData.transmit` does not provide a database commit acknowledgment.

### Vehicle ModData and client views

Vehicle ModData stores the persistent hash and the client-facing claim mirror. The server reconstructs that mirror from the registry and uses registry-backed checks for sensitive decisions. Client UI and enforcement code consume the mirrored values and server command responses.

A PostgreSQL backend still needs an in-memory server registry for synchronous authorization and a vehicle identity/mirror mechanism. Preserve the existing mirror transport and the registry-authority security properties through either migration option.

The hash generator produces a `VH`-prefixed value using a modulo-2,147,483,647 hash. PostgreSQL keys must include engine server/world scope and retain the existing hash. Duplicate hash detection during import should report a conflict. Generating new hashes during migration would break existing vehicle associations.

### File-backed database

`VehicleClaim_ServerDatabase.lua` describes its state as an export cache derived from the authoritative registry. On startup it loads indexed snapshots and the legacy JSON, then iterates registry claims to construct the active database. For each active hash, indexed data takes precedence over legacy data. Snapshot records without a registry claim are excluded from the active cache.

The default paths are relative to the engine Lua cache directory, normally `{Zomboid}/Lua`.

| Artifact | Contents and purpose |
| --- | --- |
| `VehicleClaimSystemDatabase.json` | Legacy monolithic snapshot source |
| `VehicleClaimSystemDatabase/index.txt` | JSON index with version, generation time, count, and compact car metadata/path |
| `VehicleClaimSystemDatabase/cars/<hash>.txt` | One vehicle's metadata and item summary |
| `VehicleClaimSystemDatabase/deleted/<hash>.txt` | Tombstone with version, hash, and deletion time |

The car payload contains `vehicleHash`, `ownerSteamID`, `ownerName`, `vehicleName`, `scriptName`, `x`, `y`, `lastUpdated`, `hasInventorySnapshot`, and `items`.

Each item entry contains only `fullType`, `count`, and the vehicle part/container ID. Extraction walks direct items in every vehicle part's item container. It does not recursively traverse bag contents or capture condition, food state, ammunition, attachments, item ModData, native item bytes, installed part state, vehicle damage, or a complete restorable vehicle. PostgreSQL can preserve the complete existing file payload with this same fidelity. Full restoration would be a separate feature.

The export omits `allowedPlayers`, `claimTime`, and `lastSeen`. Consequently, importing the files alone cannot reconstruct complete claims.

## Current performance behavior and gaps

The `42.19` export has meaningful workload reductions.

- Cheap checks run before inventory traversal. Snapshot extraction happens for a new entry, changed owner, position difference greater than 10 on either axis, or a missing first snapshot.
- Car write requests coalesce by hash. Vehicle-load exports have a five-minute wall-clock cooldown.
- Dirty cars and tombstones are scheduled during the 30-minute periodic flush.
- Normal queue processing performs one file operation per `OnTick`.
- Startup reconstructs the cache and schedules a full export. Shutdown drains all queued operations synchronously.

These controls have specific limits relevant to the PostgreSQL design.

1. One operation can still serialize and write an arbitrarily large car payload. The operation count limits the number of files per tick, while per-file serialization cost depends on inventory size.
2. Inventory scanning occurs in `updateCarDatabase` before the queued write. Moving SQL to a worker leaves this Lua/game-object traversal on the game thread.
3. `requestDatabaseFlush` mirrors the entire registry and iterates the database. `buildIndex` rebuilds the complete export index. Queue spreading leaves those full-collection costs intact.
4. `table.remove(pendingOps, 1)` shifts the remaining array. Queue length has no explicit capacity, and index/delete operations have weaker coalescing than car operations.
5. The car update call in successful claim handling is commented out at server commands line 756. The active call is in vehicle-load reconciliation at line 1303. A new claim can therefore receive basic metadata through registry mirroring before it receives an item snapshot.
6. Inventory-only changes do not trigger snapshot refresh when ownership and position remain unchanged and a first snapshot already exists. Existing item lists can be stale.
7. Registry mirroring changes coordinates and names, but marks an existing car dirty only when owner ID changes. Those metadata changes can remain absent from car files until another write trigger.
8. Delete operations write tombstones and retain old car files. Startup's registry filtering prevents those files from independently restoring claims.
9. Car dirty state survives a failed car write, but index dirty state is cleared at scheduling, and queued deletion state is removed before write success. There is no uniform acknowledged retry contract.
10. A shutdown drain is proportional to the entire remaining queue. The current export processing uses `OnTick`, while the entity facade supports completions during `OnTickEvenPaused`.

The last-seen helper's comment says five minutes. Its timestamp function returns game minutes from nights survived, hour, and minute. Preserve these stored units during migration and describe that clock explicitly. `lastUpdated`, cooldowns, and file tombstones use real epoch milliseconds.

The shared config comment says the writer only permits ini/cfg/txt/log extensions. The available decompiled `LuaManager` also includes json in its allowed set. Keep target-build verification separate from that older comment.

### Local sample

The local Lua cache contains a version-2 index with `count=0`, seven retained car files totaling 7,064 bytes, one tombstone, and a 19,058-byte legacy JSON. Six car files mark an inventory snapshot present and one marks it absent.

These files demonstrate why migration must select active records using the registry and validate snapshot provenance. Scanning every car file and importing it as a claim could resurrect released records. The local sample establishes no production population, production performance, or production database state.

## PvPTerritory startup header and backend selection

The recent PvPTerritory migration applies specifically to faction ranking. Zone ownership and capture systems retain their existing GlobalModData path. Its factory checks `getActivatedMods():contains("APOCALISEBR_PACK")` at server startup.

The banner uses separator lines and a persistence prefix, identifies the selected mode, and includes the platform URL, source-document location, and patch-project support link. The pack-present path initially announces detection and connectivity validation. `POSTGRESQL ACTIVE` and `MIGRATION COMMITTED` are emitted after successful asynchronous results. A missing/outdated bridge or schema failure produces `BLOCKED`. Transient operations use bounded retries with five-second delays and a single in-flight batch.

The same structure fits ClaimSystem. Suggested log states depend on the selected scope.

| State | Export-only backend wording | Claim-registry backend wording |
| --- | --- | --- |
| Pack absent | `NATIVE FILE EXPORT ACTIVE` | `NATIVE GLOBAL MODDATA AND FILE EXPORT ACTIVE` |
| Pack detected | `APOCALISEBR_PACK DETECTED - VALIDATING POSTGRESQL EXPORT STORAGE` | `APOCALISEBR_PACK DETECTED - VALIDATING POSTGRESQL CLAIM STORAGE` |
| Existing SQL state loaded | `POSTGRESQL EXPORT ACTIVE` | `POSTGRESQL CLAIM STORAGE ACTIVE` |
| Initial import acknowledged | `EXPORT MIGRATION COMMITTED` | `CLAIM MIGRATION COMMITTED` |
| Startup/write failure exhausted | `EXPORT STORAGE BLOCKED` | `CLAIM STORAGE BLOCKED` |

Use a ClaimSystem persistence prefix and link its eventual implementation document. Reuse the platform and patch support destinations from the ranking banner. In export-only mode, explicitly identify native GlobalModData as the continuing claim authority. Pack detection alone must not produce a readiness success message.

## Option A — replace the export database only

This is the recommended first implementation scope for the initial request.

- Retain `VehicleClaimRegistry` and synchronous gameplay authorization.
- Introduce a server-only export storage adapter selected once using the pack detection pattern.
- Route the car metadata, snapshot payloads, and active deletions through `ApocBR/Entities` in PostgreSQL mode.
- Preserve native files as the backend on installations without the pack.
- In PostgreSQL mode, retain memory caches and keyed dirty tracking. Submit changes from explicit claim/load/release/clear mutation points.
- Rebuild export indexes through SQL queries or a view where external consumers need them. Record external consumer requirements before retiring index/tombstone delivery.

A PostgreSQL failure affects export freshness in this option. Claim authority continues to use the native registry. The header should make that operational distinction clear. Configure bounded export retry/backpressure behavior and retain unsent dirty generations.

No database-acknowledgment barrier is needed for existing claim gameplay solely because its secondary export moved to SQL. Any future consumer that treats the export as an ownership authority would change that consistency contract and needs explicit design.

An initial SQL import should select current registry hashes, apply current registry metadata, and preserve existing snapshot fields with the same indexed-before-legacy precedence. Existing SQL initialization state should take precedence on subsequent starts, followed by explicit registry-driven additions, updates, and deletions. Avoid recurring full registry comparisons as the SQL synchronization mechanism.

## Option B — migrate claim authority and export snapshots together

Choose this scope if the desired outcome includes durable claims, access lists, and abandonment data in PostgreSQL.

Provide one claim storage abstraction used by commands, authorization, reconciliation, and export code. In PostgreSQL mode it owns an initialized in-memory registry backed by acknowledged keyed mutations. Authorization reads stay in memory. Startup readiness must be resolved before treating an unknown vehicle as unclaimed or allowing registry-dependent changes.

The command handlers currently mutate registry tables and publish results synchronously. Changing only the database file's writer would leave those claim writes in native storage. This option must adapt claim creation, remote release, contest, access grants/revocations, last-seen changes, position changes, and admin clear.

Suggested record decomposition keeps independently changing values separate.

| Collection/key | Canonical content |
| --- | --- |
| `claims/<vehicleHash>` | Owner, name, vehicle name, claim time, allowed-player map |
| `presence/<vehicleHash>` | Last-seen game time and last-known x/y |
| `vehicleMetadata/<vehicleHash>` | Script name and export metadata that changes independently |
| `inventory/<vehicleHash>` | Snapshot-present flag, captured epoch milliseconds, item summary array |
| `meta/initialization` | Schema version and completed import marker |

A claim deletion can remove all related keys in one transaction. A last-seen update submits its small presence record. Access changes replace one claim record. Inventory extraction and replacement occurs only under the chosen snapshot policy. The document API replaces the complete named record, so splitting these records prevents metadata changes from carrying the inventory blob.

If preserving the current capture policy, document that inventory summaries remain observational and can be stale. Improving inventory-only detection needs verified mutation hooks and bounded capture work. That change deserves separate acceptance criteria.

### Commit and recovery boundaries

- Publish successful ownership/access changes and their vehicle mirrors after the corresponding SQL acknowledgment. Reserve in-flight claim keys and player claim slots to enforce concurrency and claim limits.
- Serialize document batches and reuse identical expected revision, mutation UUID, and frozen body on an ambiguous outcome. The SQL contract remembers the last committed mutation. Advancing to another mutation before resolving the first would defeat that replay guarantee.
- Keep newer dirty generations when an older batch is acknowledged. Apply stale callback/session handling, especially after player disconnects and vehicle unloading.
- Separate coalescible presence updates from ownership transitions that need a commit boundary. An unchanged tick should produce zero SQL and zero inventory serialization.
- Vehicle keys are created in native inventory. SQL ownership and native inventory share no atomic transaction. Revalidate the current player/vehicle after the ownership commit and define recovery for a crash or disconnect before key delivery. Persisted delivery intent and idempotent reconciliation would be needed for a stronger handoff guarantee.
- Keep startup, conflict, retry-exhaustion, and unavailable-database behavior explicit. A pack-selected PostgreSQL mode needs a deliberate recovery path before it can safely change authority to another backend.

Admin clear needs special treatment. With four records per vehicle, one 256-operation batch covers at most 64 complete vehicle deletions. A larger clear can use a persisted clearing state with gameplay gated until resumable batches complete. Atomic visibility for arbitrarily large clears would require a generation-aware design or an extended transaction contract. The current generic API provides no unlimited atomic clear.

## PostgreSQL storage choices and the proposed new table

### Existing scoped document contract

`Entities.document(id):load(callback)` and `:mutate(revision, mutationId, operations, callback)` already provide server/world scope, atomic keyed operations, revision checks, and last-batch idempotent replay. PvPTerritory uses this contract with existing `mod_data.entity_document_state` and `mod_data.entity_document_record` tables.

A dedicated document such as `VehicleClaim.Export.v1` or `VehicleClaim.Claims.v1` gives ClaimSystem its own namespace in those existing tables. A relational view can expose claims to backend tools. This approach reuses the available transaction machinery and requires no claim-specific physical table for basic storage.

Verified limits matter when selecting it.

- Runtime batches allow 256 operations. Revision-zero import allows 100,000 operations.
- Document loads return at most 100,000 records and at most 33,554,432 aggregate Java characters across record keys and payloads. The whole document is loaded at startup, with no pagination or collection-only load API.
- Input JSON has a 33,554,432 Java-character limit and nesting depth 64. SQL additionally limits the operation JSON text to 67,108,864 bytes. Embedded payload JSON is itself a string in the outer mutation envelope, so escaping adds overhead.
- SQL requires object payloads, collection names of 1–128 characters, and record keys of 1–512 characters.
- Java shares 256 outstanding completion reservations across entity APIs and drains up to 32 completions per poll. ClaimSystem still needs its own bounded scheduling policy.
- With four records per vehicle and an initialization record, record-count capacity is at most 24,999 vehicles. Aggregate payload size may become the binding limit much earlier.

Keeping all inventory summaries in one document means they are all loaded on restart. For large populations, consider per-vehicle snapshot documents and a separate lightweight claim catalog, with an explicit design for cross-document consistency, deletion, lazy loading, and consumer queries. Alternatively extend the bridge with scoped paginated metadata/snapshot reads. Neither capability is supplied by the current single-document load.

### Dedicated physical tables

If a real new table is an explicit requirement, a plausible canonical design has `mod_data.vehicle_claim`, `mod_data.vehicle_claim_presence`, and `mod_data.vehicle_claim_inventory`, keyed by `(server_id, world, vehicle_hash)`. Add an owner lookup index on the claims table. Keep owner Steam IDs as text end to end. Current export code converts them through `tonumber`, which risks precision loss for 64-bit values. Migration cannot recover digits already lost in old exports, so validate against the authoritative registry.

The inventory table could store the existing summary JSON, with snapshot-present and capture-time fields. The generic mapper accepts scalar values and large `text`, so JSON encoding into a text column is supported. Mapping directly to a JSONB field would require bridge type support.

Creating SQL tables alone would leave two integration gaps.

1. `repo:listForServer` returns at most 256 rows and has no pagination. A server-wide claim registry can exceed this bound even when individual players have few claims.
2. Ordinary entity save/patch/delete calls are independent operations. They do not provide a coupled multi-table ownership/snapshot/delete transaction or the document contract's stable mutation replay token.

A dedicated-table implementation therefore needs scoped paging or a larger bounded read contract, plus a transactional mutation endpoint for coupled changes and ambiguous-commit reconciliation. The generic entity execution path also performs schema/primary-key validation, while the scoped document mutation avoids repeated introspection. Include that cost in the design.

Schema DDL, indexes, permissions, and transaction functions belong in the manager's game-runtime migration stream. The existing V54 grants target `pz_server_01`, so deployment must verify the effective runtime role's access. Inspect actual triggers and projections before claiming that a small mutation has bounded downstream SQL work.

## Migration and rollout design

The following is an implementation plan for later review.

1. Select export-only or canonical-claim scope and supported version folders. Identify live consumers of the file index, car files, and tombstones. The RCON-extension source search found no references to the default database filename or registry key, but that search does not establish all deployed consumers.
2. Measure production active claim counts, inventory summary sizes, total encoded data, and worst single-vehicle extraction time. The local cache is too small and stale to size production storage.
3. Deploy required engine/schema/facade support before activating the new adapter. Validate with an asynchronous scoped load and keep startup logging truthful.
4. Take coordinated recovery copies of native world data and export files. Native files, vehicle/world persistence, and PostgreSQL have separate commit boundaries.
5. On absent SQL initialization, build the import from authoritative registry claims. Validate hashes and owner IDs. Preserve access lists and game timestamps for Option B. Join indexed snapshots first, then legacy snapshots, using matching hashes. Preserve the distinction between an absent snapshot and a captured empty inventory.
6. Treat malformed indexed/legacy data as an explicit import finding. Avoid silently replacing unreadable inventory with an empty snapshot. Bound import reading, parsing, encoding, and queue work. If the one-shot import exceeds the verified limits, add a staged migration protocol and final activation marker before implementation.
7. Commit import plus initialization marker atomically when within bounds. Resolve a concurrent initialization conflict by loading the winning SQL state. An empty import still needs its marker. A database restart with existing state must not replay stale file imports.
8. Start regular mutation-driven operation only after the selected startup contract is satisfied. Retain legacy artifacts as dated recovery inputs. Switching the pack off later requires an explicit policy because native copies can lag behind SQL-backed changes.
9. Replace file consumers with scoped SQL queries/views or a deliberately scheduled compatibility export if required. Index paths and generation metadata can remain derived. Tombstone history needs explicit retention only if a consumer needs deletion events or audit history.

## Verification required before implementation is complete

- Exercise pack absent, present/healthy, missing bridge, schema error, database outage, and exhausted retry paths. Confirm banner states and gameplay behavior match the selected scope.
- Test empty/existing SQL state, indexed and legacy import precedence, malformed files, absent snapshots, stale files, tombstones, duplicate hashes, and preserved Steam ID strings.
- Verify idle ticks, repeated vehicle loads, and unchanged admission retries issue zero writes and avoid inventory traversal/serialization. Test one changed claim against thousands of unrelated records.
- Verify claim creation, owner claim limits, grants/revocations, unloaded remote release, contest, last-seen clock units, vehicle-load reconciliation, and restart behavior.
- Test mutation rollback, revision conflict, ambiguous commit replay, newer dirty generations, stale callbacks, disconnects, bounded queues, PauseEmpty, and shutdown with work outstanding.
- Verify per-car and aggregate payload limits, more than 256 claims, worst-case inventories, resumable import/clear, and bounded game-thread capture work.
- Extend the existing access-sync regression coverage and execute persistence fixtures through the installed game's Kahlua runtime. Use a disposable PostgreSQL database for schema/transaction verification and the exact target game JAR for bridge changes.

The existing `tests/vehicle_claim_access_sync.lua` covers mirror/access synchronization and stubs the database updater. It provides useful regression coverage for authorization and mirrors, while a persistence migration needs additional fixtures.

## Source locations

Claim database functions and performance constants were inspected from lines 342–945. Registry operations, command effects, and load synchronization were inspected from the companion server command file. Paths below point to the inspected local sources.

- [Claim export database](../../Contents/mods/ApocalipseClaimSystem/42.19/media/lua/server/VehicleClaim_ServerDatabase.lua)
- [Claim server commands](../../Contents/mods/ApocalipseClaimSystem/42.19/media/lua/server/VehicleClaim_ServerCommands.lua)
- [Shared identity and timestamps](../../Contents/mods/ApocalipseClaimSystem/42.19/media/lua/shared/VehicleClaim_Shared.lua)
- [Export configuration](../../Contents/mods/ApocalipseClaimSystem/42.19/media/lua/shared/VehicleClaim_Config.lua)
- [Existing access synchronization fixture](../../tests/vehicle_claim_access_sync.lua)
- [ClaimSystem README](../../readme.md)
- [PvPTerritory persistence factory](<Z:/git/Github/ApocalipseBR-PvPTerritory/Apocalipse [BR] - PvP Territory/common/media/lua/server/FactionRankPersistence.lua>)
- [PvPTerritory persistence notes](<Z:/git/Github/ApocalipseBR-PvPTerritory/Apocalipse [BR] - PvP Territory/common/media/lua/server/FactionRankPersistence.md>)
- [Pack entity facade](C:/Users/ricar/Zomboid/Workshop/apocbr/Contents/mods/ApocalisebrPack/42.14/media/lua/server/ApocBR/Entities.lua)
- [Pack entity contract](C:/Users/ricar/Zomboid/Workshop/apocbr/Contents/mods/ApocalisebrPack/42.14/media/lua/server/ApocBR/README.md)
- [Entity bridge source](Z:/git/Github/apocalipsebr-zomboid-patches/42.22.2/src/zombie/savefile/ApocBRModEntities.java)
- [Scoped mutation design and verification history](Z:/git/Github/apocalipsebr-zomboid-patches/42.22.2/docs/features/2026-11-12-scoped-record-mutations.md)
- [Game-runtime V54 SQL contract](Z:/git/Github/apocalipsebr-manager/manager/src/main/resources/db/game-runtime-migration/V54__Wallet_Record_Mutations.sql)
- [Decompiled Lua file APIs](Z:/Downloads/ZomboidDecompiler/ZomboidDecompiler/bin/output/source/zombie/Lua/LuaManager.java)
- [Decompiled global data persistence](Z:/Downloads/ZomboidDecompiler/ZomboidDecompiler/bin/output/source/zombie/world/moddata/GlobalModData.java)
- [Decompiled vehicle creation event](Z:/Downloads/ZomboidDecompiler/ZomboidDecompiler/bin/output/source/zombie/vehicles/BaseVehicle.java)
