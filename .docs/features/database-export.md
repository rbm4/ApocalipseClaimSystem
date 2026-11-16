# Vehicle database export

Implemented 2026-11-16 for the `42.19` mod folder.

`VehicleClaim_DatabaseFactory.lua` selects the export backend at `OnServerStarted`.
The active mod ID `APOCALISEBR_PACK` selects PostgreSQL. Other installations select
the native file backend. Startup logs identify selection, schema/connectivity
validation, committed import, readiness, and blocked export storage. Claim
authority continues through `VehicleClaimRegistry` in GlobalModData.

The factory installs the existing `VehicleClaim.updateCarDatabase`,
`removeFromCarDatabase`, and `clearCarDatabase` entry points. The compatibility
module `VehicleClaim_ServerDatabase.lua` loads the factory. Server commands also
notify `refreshCarDatabase` when registry position metadata changes through
last-seen updates. Successful claim creation now captures its first inventory
snapshot through the previously commented-out export call.

Persistence modules use basename imports such as
`require "VehicleClaim_DatabasePostgreSQL"`. The game registers
`media/lua/shared/` and `media/lua/server/` as search roots. Prefixing a basename
with `server/` or `shared/` searches for a nonexistent nested directory and
returns nil. The factory reports a blocked export if the PostgreSQL module fails
to provide its expected interface.

## Cache and persistence policy

`VehicleClaim_DatabaseExport.lua` owns the shared cache, reconstruction, dirty
queue, and inventory extraction. Startup joins backend snapshots to current
registry claims. Registry ownership and names overwrite exported values. Existing
snapshot contents survive reconstruction. PostgreSQL rows for claims absent from
the registry are queued for physical deletion.

An owner change, a missing first inventory snapshot, or movement greater than 10
on either axis from the last capture triggers inventory extraction. The capture
baseline is separate from metadata refreshes. Unchanged vehicle observations
perform no inventory walk, JSON encoding, or persistence request. Item arrays
are immutable once captured and include direct container items with `fullType`,
`count`, and vehicle part/container ID. Inventory-only mutations retain the
previous capture policy and can remain absent until a capture trigger occurs.

Captures update memory immediately. Persisted vehicle exports have a five-minute
cooldown, with the 30-minute flush deadline as fallback. Registry metadata changes
are coalesced until that deadline. A linked queue processes one eligible vehicle
per tick and avoids shifting an array. Acknowledgments clear only their captured
generation. Release/contest deletion has immediate queue eligibility and survives
an older save acknowledgment. Idle periodic wakeups do not scan the registry or
rebuild the PostgreSQL index.

Startup supports at most 49,999 active vehicles. The pending queue admits at most
100,000 distinct hashes, including retained deletions. Exceeding a bound blocks
the export with a log. Individual captures allow at most 100,000 direct items.
Claim gameplay continues to use the native authority.
Transient native writes retry after five seconds up to five attempts. PostgreSQL
mutations use the same retry interval and attempt bound, preserving the exact
revision, mutation UUID, and prepared body. A schema failure, revision conflict,
invalid data, or exhausted retry blocks export storage with pending memory
retained. Repair and restart reconstruct from native claims and committed
snapshots. In-memory inventory changes that never committed can be lost on a
process failure.

Polling and export scheduling use `OnTickEvenPaused`. Native shutdown drains a
bounded number of queued operations. PostgreSQL shutdown reports pending work
and relies on the engine persistence worker's lifecycle. Shutdown completion of
an asynchronous export is not guaranteed by the Lua module.

## Native backend

`VehicleClaim_DatabaseNative.lua` retains the configured
`VehicleClaim.Sync.filename`, defaulting to `VehicleClaimSystemDatabase.json`.
It reads active indexed snapshots first and falls back to the legacy monolithic
snapshot for hashes absent from the index. Malformed or missing indexed payloads
raise an explicit startup error.

Files remain under the engine Lua cache directory.

| Path | Content |
| --- | --- |
| `VehicleClaimSystemDatabase/index.txt` | Version-2 compact active-vehicle index |
| `VehicleClaimSystemDatabase/cars/<hash>.txt` | Vehicle metadata and item summary |
| `VehicleClaimSystemDatabase/deleted/<hash>.txt` | Archived vehicle payload with `deletedAt` and version |

The Lua file API has no unlink/rename operation. A release first writes the
archive, then replaces the old car payload with a small deletion marker. The
active index excludes the vehicle. Index rewrites happen at startup or when a
dirty index reaches the normal flush deadline. A failed archive/retirement write
retains its pending operation.

## PostgreSQL backend and schema

Apply manager migration `V58__Vehicle_Claim_Database_Export.sql` through the
game-runtime Flyway stream. V54 scoped mutations and the updated entity bridge
and pack facade must already be installed. The engine role is `pz_server_01`.
The migration includes schema, table, sequence-default, and function grants.

The factory defines two scalar entity mappings and validates their schemas
asynchronously before loading the export. Those checks also establish connection
and read permissions. The mappings target the following tables.

| Table | Per-vehicle fields |
| --- | --- |
| `mod_data.vehicle_claim_export_index` | Owner Steam ID/name, vehicle/script name, x/y, last-updated epoch milliseconds, revision |
| `mod_data.vehicle_claim_export_items` | Snapshot-present flag, `items_json` text containing the summary array, revision |

Both use `(server_id, world, vehicle_hash)` as primary key. An owner lookup index
supports scoped player queries. Steam IDs remain strings throughout the export.
The item table references the index with a deferred cascading foreign key.
The native index's count is available through a scoped SQL count. Filesystem
paths and a global regenerated index document are unnecessary in PostgreSQL.

Saves use `ApocBREntities.document("VehicleClaim.Export.v1")`, with `index/<hash>`
and `items/<hash>` records. This preserves the bridge's existing atomicity,
optimistic revision checks, idempotent replay, engine scope, and bounded worker.
A row trigger projects each changed record into its corresponding dedicated
table inside the same transaction. These query tables are maintained by that
document contract. Writing them independently bypasses the canonical store.
Canonical item records and their query-table projection both occupy database
storage. The projection touches only the named vehicle and performs no
full-collection sweep.

Metadata-only saves submit just the index record and leave the item row
untouched. Capture saves include the new item record. Release, contest, and admin
clear remove the vehicle's canonical index/item records and physically delete
their dedicated table rows. Admin clear progresses as bounded per-vehicle export
transactions while native registry clearing remains authoritative.

`meta/initialization` records schema version 1. On first use, the backend imports
current registry hashes and joins their indexed/legacy native snapshots. Stale
unindexed files are excluded. The entire initial import and marker share one
revision-zero transaction. Empty imports still commit the marker. Later startups
load existing SQL state without rereading native snapshots, then reconcile it
with the current registry. Switching between native and PostgreSQL exports does
not copy new SQL inventory summaries back to disk automatically.

The existing bridge loads at most 100,000 document records with a 32 MiB Java
character aggregate limit. Runtime batches allow 256 operations. Initial imports
allow 100,000 operations and the same aggregate encoding bound, including JSON
escaping overhead. Limits block export startup or writes explicitly. This
implementation does not paginate a document or import oversized datasets in
stages. Both game-thread snapshot extraction and JSON preparation still cost
time proportional to the captured vehicle inventory.

## Deployment and verification

Deploy V58 before activating the new mod scripts. Deploy the complete `42.19`
server module set together. The older version folders retain their existing
implementations. Startup success is confirmed by `POSTGRESQL EXPORT ACTIVE`
after both schema checks and cache load/import acknowledgment.

Run `py -3 tests/run-database-export-kahlua.py` from the mod root for production
Lua factory/cache/backend tests using the actual pack facade and game Kahlua.
The bridge and filesystem are detached asynchronous doubles. The existing
access synchronization fixture also covers registry/mirror behavior.

Manager `VehicleClaimExportMigrationTest` runs with
`GAME_RUNTIME_TEST_POSTGRES_URL` targeting a disposable loopback PostgreSQL
cluster provisioned with migration and engine roles. It verifies Flyway rerun,
engine permissions, both tables, metadata-only writes, scoped physical deletion,
rollback, idempotency/conflicts, empty inventories, and mutation work with
1,200 unrelated vehicles. Dedicated-server load/restart and live performance
measurements remain deployment verification tasks.

Local verification on 2026-11-16 passed all seven migration tests on disposable
PostgreSQL 17.6 with separate migration/engine roles and no skipped tests. The
Maven wrapper used `-Dmaven.resources.skip=true` to omit unrelated map resource
copying. The production Kahlua fixture passed 1,650 export checks, including
admin clear across 1,200 vehicles. The existing access-sync fixture also passed.
Database validation was isolated from deployed servers.

The subsequent startup import fix passed 1,730 Kahlua checks and the access-sync
fixture. The test loader now resolves the actual server/shared search roots,
rejects the previously accepted incorrect prefixes, caches module returns by
resolved filename, and exercises automatic loading before startup as well as
require-first loading. The initial fixture accepted incorrect imports, leaving
that startup failure uncovered. Deployment of the corrected scripts requires a
server restart so its Lua module cache is rebuilt.

The earlier [investigation](../reports/2026-11-16-postgresql-claim-persistence-investigation.md)
records the original architecture and alternatives.
