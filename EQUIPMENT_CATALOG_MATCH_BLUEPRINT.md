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
  a Claude Skill that consumes the catalog endpoint), checking real per-date
  availability via HireTrack's own `api_v2` booking engine.
- Write: matched items into a HireTrack **Note** (`Notebook`/`notebookdetails`,
  lightweight) or a **real Job + Eqlist booking** (via `api_v2`, heavier) --
  both wrapped into this service's own operations, see "Write paths" below.

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

## Write paths: Note vs. real booking

Two write paths now exist, both wired into this service's own operations
(no ad-hoc scripts needed for either):

### Note (`Notebook`/`notebookdetails`) — lightweight, no Job created

Uses the general "Note" write pattern documented in
[DB_QUERY_REFERENCE.md § Writing to HireTrack](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/DB_QUERY_REFERENCE.md)
(`CreateNewNote` via ODBC `CALL` escape + plain `INSERT INTO notebookdetails`,
all three price columns set, `priceEach` optional and falling back to
`Hetype.Daily` when omitted) — implemented in
`hiretrack_equipment_note_write.py` as the `create-note`/`add-note-line`
operations, wrapped by `hiretrack-equipment-note-write.ts` /
`createEquipmentNoteWithLines`. `:Eqtype` in that pattern is exactly the
`Hetype.Type` the matching step (in the Claude Skill) produces.

Transport: pyodbc, same bridge-script style as the read operations, but
through a separate writable DSN/connection (`HIRETRACK_WRITE_ODBC_DSN`,
currently the `Claude` DSN on the server). The existing `HireTrack DSN` used
by `hiretrack_stocktake_read.py` for reads is explicitly read-only — never
point write operations at it.

### Real booking (Job + Eqlist) — via `api_v2`, not raw `Sort` inserts

Superseded the earlier "raw `INSERT INTO Sort`, ad-hoc, unproven totals
recalculation" approach entirely (2026-08-09): HireTrack NX ships its own
booking-write REST API (`api_v2`, on the same HTTP gateway/port used for the
existing `api_v1` QBE lookups already in this codebase —
`hiretrack-eqlist-lookup.ts`, `hiretrack-equipment-lookup.ts`,
`hiretrack-repair-create.ts` — same `hiretrack.config.json` `baseUrl`/
`headers`). `hiretrack-booking-api.ts` wraps three `api_v2` actions:

- `initialise_new_booking` — creates a real Job + Eqlist and its first line
  in one call.
- `append_to_booking` — adds one more line to that Eqlist.
- `check_availability` — see the availability section below.

`createHiretrackBooking()` batches these (1 `initialise` + N-1 `append`
calls) the same way `createEquipmentNoteWithLines()` batches Note lines,
exposed as `POST /lookups/equipment-bookings`.

**Confirmed live (2026-08-09)** against production, using the dedicated
"Test client" (`Company.CompanyCounter = 2`) so no real customer was
touched: `initialise_new_booking` created Job 7182 / Eqlist 10647 with
correct `JobRef`/`EqRef`; `append_to_booking` added a second line with
correct pricing pulled from the client's price list (list price, discounted
price, discount rate all correct); `delete_job` cleanly removed the whole
test booking afterward. **The doc's own header labels `check_availability`
and other actions as `GET`, but the actual working method is `POST`** — GET
returns a 500 ("No item found with name...") — confirmed against the doc's
own curl examples, which do use `--request POST` despite the mislabeled
`GET` header text above them.

Needs a **real `hiretrack_client_id`** (`Company.CompanyCounter`) — this is
who the booking is made for, so unlike the Note path it must come from the
user, not be defaulted. `hiretrack.config.json` fallback defaults used when
not overridden: `defaultUserId` 1 (`HireTrack_Admin`), `defaultWarehouseId`
1 (`Moscow`), `defaultPricelistId` 6 (`SA Rental Scheme`), `testClientId` 2
(`Test client` — availability checks only, never use for a real booking).

## Endpoint surface (this feature)

- `GET /lookups/equipment-catalog` — served from the persisted/delta-synced
  in-memory snapshot described above (`/tickets/...` and `/api/tickets/...`,
  same as other `/lookups/*` routes; behind the existing password-auth cookie
  gate).
- `GET /lookups/equipment-availability` — real per-date-range availability
  for one type via `check_availability` (see below).
- `POST /lookups/equipment-notes` — creates a Note + lines from a confirmed
  match list.
- `POST /lookups/equipment-bookings/initialise`, `.../append` — low-level
  single-`api_v2`-call wrappers.
- `POST /lookups/equipment-bookings` — batched real-booking creation
  (`createHiretrackBooking`), the one the Skill actually calls.

All write endpoints require callers to have already gotten explicit user
sign-off on the line list before calling — real writes to production
HireTrack data.

## Shipped: availability-aware matching (2026-08-09)

Found live (2026-08-06): matching originally only looked at the `Hetype`
catalog (equipment *types*), with zero visibility into physical stock.
Concretely - "Professional Music Stand" (`Type 660`) was matched and
inserted for a rider line, but `Type 660` has **0 physical `Item` rows**,
while a near-identical generic option, "Пюпитр Ultimate JS-MS200"
(`Type 1203`), has ~206. The matcher picked the zero-stock one purely on
text similarity.

Originally planned as a hand-rolled formula over `Sort`/`Whlevel`/`Item`
with unresolved `Sort.Defcon` semantics (see git history for that draft) —
**scrapped entirely** once `api_v2`'s `check_availability` was found: it
computes real date-range availability server-side (HireTrack's own booking
engine, not a reimplementation), so there's no `Defcon` reverse-engineering
needed at all.

**Confirmed live (2026-08-09)** against both known cases: `Type 1203`
(healthy stock) returned `StocklevelForWarehouse: 141`,
`AvailableQty: 130` for a real date range with correct discounted pricing;
`Type 660` (the original bad match) returned `StocklevelForWarehouse: 0`,
`AvailableQty: 0`, `BookingQty: 0` — exactly the case that should have been
caught originally.

Shape: `GET /lookups/equipment-availability?typeId=&quantity=&dateFrom=&dateTo=&warehouseId=&clientId=&pricelistId=&userId=`
— on-demand, one type per call, **not** part of the static
`equipment-catalog-full`/`-changes` sync (availability is date-scoped and
dynamic, unlike the mostly-static Hetype catalog). The Claude Skill calls
this per shortlisted candidate during matching (not the whole 7000+
catalog), after narrowing to a likely match — see `SKILL.md` Step 5.

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

## Consumers

- A Claude Skill (`hiretrack-rider-match`, outside this repo) is the
  rider-parsing/matching/write-triggering client of this API. This repo only
  owns the read/write primitives above.
- **`/create-job/` page (2026-08-09)** — a manual, in-app alternative to the
  skill, for when rider parsing/matching isn't needed (or is deliberately
  deferred): client search (new `company-search` read operation, since
  `initialise_new_booking` needs a real `Company.CompanyCounter`), date
  range, equipment search over the same catalog cache with live per-line
  `check_availability`, submits via `createHiretrackBooking`. Same
  PIN-gate pattern as `/crew-bookings/` (`create-job-pin-auth.ts`,
  `CREATE_JOB_PIN`) since it writes real Jobs/Eqlists. Source:
  `backend/src/routes/create-job.ts`, `frontend-create-job/`.
- **"Open an existing job" mode (2026-08-09)**, same page — a mode toggle
  switches from creating a new booking to looking up an existing one by
  Job Ref (new `job-lookup` read operation: `Jobs` → `Eqlists` → `Sort`+
  `Hetype`), shows what's already on it, and appends more equipment via
  `appendLinesToExistingBooking`. Deliberately uses the target Eqlist's
  own `DateOut`/`DateBack` (from the lookup) for every appended line
  rather than asking the user to re-enter dates — `append_to_booking`
  rejects any mismatch with `ValidationResult: 6`
  (`bvrBookingDatesNEQListDates`), so this is not just a UX shortcut, it's
  required for the write to succeed at all. Job Ref lookup itself is an
  exact (trimmed) match, not case-insensitive — `UPPER()`/`LOWER()` don't
  fold Cyrillic case in this NexusDB instance (confirmed live).
  **Finding the Job Ref is interactive, though**: users know the client or
  job name, not the ref, so a new `job-search` read operation
  (`Job_Title`/`Name`/`Job_Ref` `LIKE`) powers a debounced type-ahead
  dropdown (same pattern as the client search) — type a name, get matching
  job numbers to pick from, click one to open it via the exact-match
  lookup above.
  **Nested Sections view with equipment-type badges (2026-08-09)**:
  `job-lookup` also reads `Sort.sectionID` + `EqSections` (`SectionText`)
  and `Hetype.EquipmentType` per line, so the existing-job equipment list
  renders as a Section → line tree instead of a flat table, each line
  tagged with a colored badge (Normal/Composite/Alias/Priced Alias/
  Markup). Composite/Alias lines nest their real components underneath —
  pulled from the catalog cache already loaded for the equipment search
  (`state.catalogById` client-side, same `COMPOSIT` data used for rider
  matching), no extra fetch. Verified against real data: Job `Р7167МСК`
  has one section ("Default Section Header") and a genuine Composite line
  (`Type 446`, "TC Electronic M6000") alongside plain lines.
  **Edit quantity / remove a line (2026-08-09)**: `job-lookup` also reads
  `Sort.Lineref` per line (the same id `append_to_booking` returns as
  `LineRefID`), so each line in the tree has an editable qty input and a
  Remove button, wired to two more `api_v2` actions —
  `change_booking_quantity` and `remove_from_booking` — both wrapped with
  the same `ValidationResult` check as the rest of the booking-write path.
  Only top-level lines (real `Sort` rows) are editable; nested Composite/
  Alias component rows stay read-only, since they're catalog metadata, not
  separate bookable lines. Verified live: changed a line's qty (confirmed
  correct pricing recalculation) then removed it, confirmed gone via a
  direct `Sort` read.
  **Fixed double-display of a Composite's own components (2026-08-09)**:
  a Composite/Alias line's declared `COMPOSIT` components often *also*
  exist as their own separate `Sort` rows in the same section (for stock
  tracking) — confirmed live on `Р7167МСК`: `Type 446`'s real recipe
  (447/448/449) exactly matches three other lines already on the same
  job. These were rendering twice (standalone AND nested under the
  Composite). Fixed: a top-level line is now skipped and shown only
  nested under its parent Composite/Alias if its `typeId` matches one of
  that Composite's declared components within the same section — using
  the real persisted line's quantity (more authoritative than the
  catalog recipe's default) when a match exists.
  **Letter badges, reordered layout, availability column (2026-08-10)**:
  the full-word type badges (Normal/Composite/Alias/Priced Alias/Markup)
  became single-letter badges — N/C/A/M, plus a new **C = Consumable**
  category sourced from `Hetype.Class` (not `Hetype.EquipmentType` — a
  separate axis; confirmed live via `"#Fields"."FIELD_DESC"` for
  `TABLE_NAME='Hetype', FIELD_NAME='Class'` = `"ecRental, ecConsumable,
  ecNewSales, ecExRentalSales (0..3)"`, cross-checked against live
  distinct-value counts: 0→1906, 1→186, 2→75, 3→142 rows). `Class` is now
  plumbed through `job-lookup`'s `Sort`/`Hetype` join alongside
  `EquipmentType`. Badge colors: Composite = mustard yellow, Alias = dark
  green, Consumable = magenta; Priced Alias folds into the Alias letter/
  color, Markup keeps the neutral/gray styling. Each line's layout is now
  badge → qty → name → availability → remove, with the internal Type ID
  no longer displayed and the "Удалить" text button replaced by a plain
  red "×". A new per-line availability column shows compact
  `свободно / всего` (e.g. `137 / 141`), fetched asynchronously per line
  against `GET /api/create-job/availability` using the job's own
  `dateFrom`/`dateTo` — colored the same ok/low/none as the new-booking
  staging table's availability badges. Verified against a local mock of
  `/api/create-job/catalog` + `/jobs/:jobRef` + `/availability` covering
  a Normal, Composite (with absorbed components), Alias (0 available),
  and Consumable line, rendered correctly in-browser before deploying.
  **Composite spoiler, qty-first components, self-aware availability
  (2026-08-10)**: three follow-up fixes to the tree view. (1) The
  Composite/Alias components list now shows quantity before the name
  (`×1 M6000 - блок`, not the other way round). (2) That nested list is
  now a collapsible spoiler — collapsed by default, a `▸`/`▾` toggle on
  the parent line reveals it — instead of always being expanded. (3) The
  per-line availability number is now self-aware: `check_availability`
  has no notion of "this specific already-persisted line", so its raw
  `AvailableQty` for a type/date range already has this job's own
  currently-booked quantity for that line subtracted out along with
  everyone else's overlapping bookings — naively displaying that raw
  number makes a line look short on stock even when the shortfall is
  entirely its own reservation. Fixed by displaying `rawAvailableQty +
  line.qty` instead (the real headroom for growing this exact line), with
  the ok/low/none color threshold changed to compare `rawAvailableQty`
  against zero rather than the requested quantity against the raw number.
  No artificial cap was ever added preventing a quantity higher than the
  displayed number — increasing past it is allowed by the UI in either
  case; HireTrack's own `change_booking_quantity` validation is the real
  arbiter and any rejection still surfaces through the existing
  `ValidationResult` error path. Separately, quantity edits via the
  number input's native stepper arrows (each click fires its own
  `change` event immediately) were debounced and switched from
  "PUT then refetch+rebuild the whole tree" to "PUT then mutate state and
  refresh just that line's own availability badge in place" — rapid
  stepper clicks previously triggered a full tree rebuild per click
  (visible flicker, lost focus); verified in-browser that two rapid
  stepper clicks now produce exactly one PUT request and leave the tree
  container's own DOM node untouched (only the edited line's text/class
  updated).
  **Availability formula simplified, component qty format fixed, section
  CRUD added (2026-08-10, later same day)**: the `rawAvailableQty +
  line.qty` "headroom" calc above was replaced at the user's request with a
  much simpler figure — just `stocklevelForWarehouse - line.qty` (active
  stock in the warehouse minus what this job itself has booked for this
  line), deliberately ignoring what other jobs have booked. Displayed as a
  single signed remainder (e.g. `-2`) instead of `X / Y`: green when
  positive, yellow at exactly zero, red with its sign when negative — still
  never blocking entry of a quantity larger than what's shown. Also: nested
  Composite/Alias component lines now read `1 × Name` (quantity first, not
  `×1 Name`). Bigger addition: full CRUD for `EqSections` from the
  existing-job tree — rename inline (pencil icon, commits on blur/Enter,
  Escape cancels), create (a "+ Добавить секцию" control always at the
  bottom of the tree), and delete (native `confirm()` warning first, since
  it's a real production row). Every known section now renders even with
  zero lines (previously a section with no lines was skipped entirely,
  which would have hidden a freshly-created empty section). Deleting a
  section reassigns its lines to "no section" (`Sort.sectionID = NULL`)
  rather than leaving them pointing at a deleted row. Three new write
  operations (`rename-section`/`create-section`/`delete-section`) added to
  the Python write bridge + Node wrapper + routes, live-verified against a
  throwaway section created and deleted on the real `Р7167МСК` test job
  before shipping: `EqSections.idx` is `LASTAUTOINC`, same pattern as
  `CreateNewNote`; `sortOrder` is a plain `FLOAT` (new sections append after
  the current max); `Sort.sectionID` accepts `NULL`. No leftover test data
  — the throwaway section was renamed, then deleted, confirming all three
  operations before the real feature was built.
  **Per-section equipment entry, replacing the shared staging table
  (2026-08-10, later same day)**: for existing-job mode, the single
  "Добавить оборудование" card (search + staging table + batch submit
  button, shared with new-job creation) was replaced by a small widget at
  the top of every section — search input + inline qty, no staging step,
  Enter/click adds the line immediately. New-job creation keeps the old
  shared flow unchanged (no sections exist before a job is created), so
  `#equipment-card`/`.submit-card` are now simply hidden whenever
  `state.mode === 'existing'`.
  **Section-targeted appends needed a new write op**: `api_v2`'s
  `append_to_booking` has no section parameter at all — a freshly appended
  line lands wherever HireTrack itself decides (observed live: an
  auto-created "Warehouse Added Equipment" section), regardless of which
  section's widget the user actually searched from. Fixed with
  `set-line-section` (`UPDATE "Sort" SET "sectionID" = ? WHERE "Lineref" =
  ? AND "Eqlno" = ?`), called right after a successful append whenever the
  line carries a `sectionId`. Live-verified end-to-end via the real write
  bridge script (not just ad-hoc SQL) on the `Р7167МСК` test job: moved a
  real line (251791) from section 17291 to 17293, confirmed via a direct
  `Sort` read, then moved it back to restore the original state.
  `appendLinesToExistingBooking`'s line type gained an optional
  `sectionId`, threaded through from the `/jobs/:jobRef/lines` route.
  **Search UX**: each per-section widget filters the already-cached
  catalog client-side (same substring match as the old shared search),
  shows availability directly on each result row in compact `X/Y` form
  (fetched as the dropdown opens, keyed to a per-search token so a fast
  typist's stale in-flight fetches never overwrite a newer search's
  results), and supports `ArrowUp`/`ArrowDown` to move a highlighted row
  plus `Enter` to add the highlighted (or, if none highlighted yet, the
  top) result — mouse users can also click a row directly. After a
  successful add, the tree reloads and refocuses that same section's
  search box, so entering a run of items stays a tight type → Enter →
  type → Enter loop without the cursor jumping away. Verified in-browser:
  typing "Кабель" surfaced 4 matches with availability filled in
  immediately, two `ArrowDown` presses highlighted the correct (second)
  row, `Enter` added it with the qty typed into the inline field, it
  appeared in the correct section with the correct self-aware remainder,
  and focus returned to that section's own search box afterward.
