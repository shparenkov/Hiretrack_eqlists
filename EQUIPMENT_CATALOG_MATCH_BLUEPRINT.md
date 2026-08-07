# Equipment Catalog Match Blueprint

This doc covers the **rider-matching feature specifically** — endpoints, sync
design, and how the Claude Skill uses them. General HireTrack schema facts,
NexusDB/pyodbc driver quirks, and the two confirmed write patterns (Note vs.
direct `Sort` insert) now live in
[DB_QUERY_REFERENCE.md](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/DB_QUERY_REFERENCE.md)
instead — that's the cross-project reference, this doc just applies it.

## Goal

Let a user upload a touring collective's technical rider (any format — PDF,
DOCX, XLSX, plain text) and get back the closest-matching equipment from our
own HireTrack NX stock (`Hetype.Type` IDs), then optionally write the matched
items into HireTrack as a Note (`Notebook`/`notebookdetails`).

This builds on the same "read HireTrack live without QBE" approach already
used for stock-take history in this app: a bundled 32-bit Python script using
`pyodbc` against a local ODBC DSN, spawned by the Node backend, running on the
same Windows Service (`HireTrackStocktakes`, port 3001) already in production.
No new service, no new port.

## Scope

- Read: full equipment-type catalog (`Hetype` + `category`), kept in sync via
  a delta feed instead of full re-queries.
- Match: rider line items -> `Hetype.Type` (external to this backend; lives in
  a Claude Skill that consumes the catalog endpoint).
- Write: matched items into a HireTrack **Note** (`Notebook`/`notebookdetails`)
  via this service's own operations. Direct Eqlist (`Sort`) writes are
  possible (see "Write path" below) but not wrapped into this service yet.

## Read path: `equipment-catalog-full` / `equipment-catalog-changes`

Two new `operation`s in
`backend/python/hiretrack_stocktake_read.py` (same dispatch-by-`operation`
shape as the existing `stocktake-history` operation):

### `equipment-catalog-full`

Run once ever (first sync, or an explicit forced resync) — this is the
expensive full join over 7000+ rows:

```sql
SELECT
  H."Type" AS EquipmentTypeId,
  H."Description" AS EquipmentName,
  H."Shortcode" AS Shortcode,
  H."Comments" AS Comments,
  H."LongDescription" AS LongDescription,
  CAST(H."Class" AS SMALLINT) AS Class,
  CAST(H."Visibility" AS SMALLINT) AS Visibility,
  CAST(H."EquipmentType" AS SMALLINT) AS EquipmentType,
  H."xSimilar" AS SimilarGroupId,
  SIM."Name" AS SimilarGroupName,
  C."Category" AS CategoryId,
  C."Description" AS CategoryName
FROM "Hetype" H
LEFT JOIN "category" C ON C."Category" = H."Category"
LEFT JOIN "Similars" SIM ON SIM."IDX" = H."xSimilar"
```

(`CAST(... AS SMALLINT)` on `BYTE` columns and the accessories/`COMPOSIT`
reads that go alongside this query are general NexusDB/schema facts — see
`DB_QUERY_REFERENCE.md`.)

**Do not join `Company`/`Hetype.xManufacturer`, and do not select
`Hetype.MPN`** — those are supplier/purchase-source fields, not brand/model.
See [DB_QUERY_REFERENCE.md](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/DB_QUERY_REFERENCE.md)
for why; this was already tried and reverted once.

### `equipment-catalog-changes`

Cheap, indexed delta read — drives every refresh after the first:

```sql
SELECT L."MasterID" AS EquipmentTypeId, L."ActionID" AS ActionId, L."EditDate" AS EditDate
FROM "Lookups_LOG" L
WHERE L."TableName" = 'HeType' AND L."EditDate" > :Since
ORDER BY L."EditDate"
```

`Lookups_LOG` is populated by trigger `trHeType_LOG` (`db.sql:20699`) on every
insert/update/delete of `HeType`: `ActionID` 0 = insert, 1 = update,
2 = delete. This is the same "change detector" pattern already used for Jobs
via QBE 44, applied here to `HeType`.

For `ActionId` 0/1 rows: re-fetch just those `Type` IDs with the same join as
`equipment-catalog-full` (`WHERE H."Type" IN (...)`). For `ActionId` 2 rows:
remove that `Type` from the cached snapshot.

### Caching contract (why this matters)

**The catalog must never be re-queried in full on a normal refresh cycle** —
7000+ rows, and DB resources on this server are limited. The Node service
(`hiretrack-equipment-catalog.ts`) keeps:

- an in-memory `Map<Type, Item>` snapshot
- a `lastSyncAt` timestamp
- both **persisted to disk** (JSON, same pattern as `runtime/poller-state.json`
  elsewhere in this project) so a service restart/redeploy loads the existing
  snapshot instead of forcing a fresh `equipment-catalog-full` run

Refresh cycle (time-based, `EQUIPMENT_CATALOG_SYNC_MS`, default ~5-10 min):
call `equipment-catalog-changes` with `Since=lastSyncAt`, apply
inserts/updates/deletes, persist, advance `lastSyncAt`. `GET
/lookups/equipment-catalog` is served straight from the in-memory map — no DB
round-trip on read.

## Write path: Note (`Notebook`/`notebookdetails`)

Uses the general "Note" write pattern documented in
[DB_QUERY_REFERENCE.md § Writing to HireTrack](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/DB_QUERY_REFERENCE.md)
(`CreateNewNote` via ODBC `CALL` escape + plain `INSERT INTO notebookdetails`,
all three price columns set, `priceEach` optional and falling back to
`Hetype.Daily` when omitted) — implemented in
`hiretrack_equipment_note_write.py` as the `create-note`/`add-note-line`
operations. `:Eqtype` in that pattern is exactly the `Hetype.Type` the
matching step (in the Claude Skill) produces.

### Transport and DSN

`create-note`/`add-note-line` go through pyodbc, same bridge-script style as
the read operations — **but through a separate writable DSN/connection**
(`HIRETRACK_WRITE_ODBC_DSN`, currently the `Claude` DSN on the server). The
existing `HireTrack DSN` used by `hiretrack_stocktake_read.py` for reads is
explicitly read-only — never point write operations at it.

### Status

**The skill's built-in write path (`create-note`/`add-note-line`) targets
Notes only.** Direct writes to a live Eqlist (`Sort`) are now confirmed to
work (see the write pattern in `DB_QUERY_REFERENCE.md`, tested live against a
job created specifically for testing, not a real booking) but aren't wrapped
into this service's operations yet — done so far via ad-hoc Python scripts
against the writable DSN. Before wiring this into the skill/service properly:
confirm whether job/eqlist header totals recalculate correctly from a raw
insert, and behavior when the destination Eqlist already has its own
sections (only tested against an empty Eqlist so far).

## Endpoint surface (this feature)

- `GET /lookups/equipment-catalog` — served from the persisted/delta-synced
  in-memory snapshot described above (`/tickets/...` and `/api/tickets/...`,
  same as other `/lookups/*` routes; behind the existing password-auth cookie
  gate).
- `POST /lookups/equipment-notes` (or similar — see route file for the
  landed name) — creates a Note + lines from a confirmed match list. Callers
  must have already gotten explicit user sign-off on the line list before
  calling this; it is a real write to production HireTrack data.

## Planned (not built yet): availability-aware matching

Found live (2026-08-06): matching currently only looks at the `Hetype` catalog
(equipment *types*), with zero visibility into physical stock. Concretely -
"Professional Music Stand" (`Type 660`) was matched and inserted for a rider
line, but `Type 660` has **0 physical `Item` rows**, while a near-identical
generic option, "Пюпитр Ultimate JS-MS200" (`Type 1203`), has ~206. The
matcher picked the zero-stock one purely on text similarity. Desired end
state per the user: full **date-aware availability** (how many are free for
the specific rider dates, not just total owned), not just a static stock
count.

### What's confirmed so far

- No server-side function computes this - the "Avail" column in HireTrack NX
  is calculated client-side, nothing to just call.
- Total owned count per `Type` = `SELECT COUNT(*) FROM Item WHERE Type = ?`
  (cross-checked against `Whlevel.SiteOwns` for a few types, they agree).
- Candidate formula, validated on exactly **one** live example so far (music
  stand: 0 owned, one qty=1 reservation, NX showed `Avail = -1`, matching
  `owned - reserved`):
  `Avail = owned_item_count - SUM(Quant) over other Sort rows for that Type
  where [D1,D2] overlaps the target [DateOut,DateBack] and the row counts as
  an active booking (not virtual, not a cancelled/draft status)`.

### What's still unresolved - do this before implementing

- **`Sort.Defcon` / `defcon` table semantics are not reliably known.** The
  `defcon` lookup has a `Function` column (0/1/2/3 seen) that looks like it
  groups statuses into severity/activity tiers, and a `System` boolean, but
  which combination means "counts against availability" vs "cancelled/draft,
  ignore" has NOT been empirically confirmed - only one data point exists so
  far, which didn't exercise this at all (no competing bookings). Validate
  against 2-3 real examples where a type has multiple overlapping-date
  bookings with different Defcon values, by comparing computed Avail against
  what the NX client actually shows for the same Type/date range.
- Whether `Whlevel` (per-site stock) needs to be split by `xSite`/warehouse
  rather than summed, once multi-warehouse cases come up.

### Proposed shape once validated

- **Not** part of the static `equipment-catalog-full`/`-changes` sync (Part
  A) - availability is date-range-scoped and highly dynamic, so it can't be
  pre-cached the same way the mostly-static Hetype catalog is.
- A separate **on-demand** endpoint, e.g.
  `GET /lookups/equipment-availability?dateOut=...&dateBack=...&types=1,2,3`,
  computed per request for the specific rider's dates.
- Claude Skill matching step calls this after shortlisting candidates (not
  for the whole 7000+ catalog), and prefers/flags candidates by availability
  for the requested qty, instead of picking on text-match score alone.

## Implemented: Similars taxonomy + Composite/Alias kit + accessory awareness

Built live (2026-08-06), after several rider tests produced matches the user
felt were "not quite understandable" - raw text-overlap matching against
2300+ `Hetype` names was the wrong primary signal. The underlying schema
facts (`Similars` taxonomy, `Hetype.EquipmentType`, `related` accessories,
`COMPOSIT` kit recipes) are documented in
[DB_QUERY_REFERENCE.md § equipment_catalog](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/DB_QUERY_REFERENCE.md) -
this section only covers how *this feature* exposes and uses them:

- `equipment-catalog-full`/`-changes` now also read `Similars` (via
  `Hetype.xSimilar`), `Hetype.EquipmentType`, `related` (as `accessories`),
  and `COMPOSIT` (as `components`) on every catalog item - same query
  family, no new sync mechanism (see `hiretrack-equipment-catalog.ts`).
- The `hiretrack-rider-match` skill's pre-filter script weights
  `similarGroupName` overlap heavily, gives a small nudge to
  Composite/Alias/Priced-Alias types, and surfaces `accessories`/`components`
  in its output; `SKILL.md`'s matching step checks the Similars group first,
  verifies a Composite/Alias kit's actual `components` before picking it, and
  treats `required: true` accessories as part of the match.
- Concrete wins already seen: `Type 33` "Zildjian A Custom 14\" Hi-Hats"
  (Composite Kit) now gets picked as one line instead of manually matching
  top+bottom separately; the Shure wireless "Alias"/"Priced Alias" types
  (`Axient - AD1/B58a/SM58`, `PSM1000`, `PSM Axient`) turned out to already be
  how the wireless-system matches in earlier rider tests were done, without
  the mechanism being understood at the time.

## Consumer

A Claude Skill (`hiretrack-rider-match`, outside this repo) is the actual
rider-parsing/matching/write-triggering client of this API. This repo only
owns the read/write primitives above.
