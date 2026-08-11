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
  **Availability caching, nested qty field, seamless line insert
  (2026-08-10, later same day)**: the per-search "fetch every visible
  result's availability" approach above still re-fetched the same typeId
  every time it reappeared across refined/re-typed search queries — the
  user flagged this as unnecessary database load. Replaced with a
  per-loaded-job client-side cache (`state.availabilityCache`, `Map<typeId,
  {availableQty, stocklevelForWarehouse}>`), which also caches in-flight
  promises so concurrent requests for the same typeId (e.g. several result
  rows resolving at once) share one fetch instead of each firing its own.
  A single `getAvailability(typeId, loadedJob)` helper now backs the tree's
  per-line remainder, every search result row, and newly-inserted lines -
  the cache is reset only when a genuinely different job is opened (dates
  can differ), never on a same-job add/search. This is a deliberately
  narrower scope than a literal "preload the whole multi-thousand-item
  catalog upfront" reading of the request would have been - that would
  mean thousands of individual `api_v2` HTTP calls before the page is even
  usable (no bulk endpoint exists to do this in one query without
  re-implementing HireTrack's own availability logic, which risks getting
  subtly wrong). The chosen "fetch once per typeId per job, reuse forever"
  approach directly addresses the stated problem (redundant re-fetching)
  without that risk or the wait.
  Second change: the qty field moved from a separate box next to the
  search input into one shared bordered box with it (`.section-add-box`,
  qty inset on the right, no individual borders on either input) - visibly
  "nested inside" rather than beside.
  Third: the keyboard flow now matches the user's described 4-step
  sequence exactly - `ArrowUp`/`ArrowDown` moves the highlighted result
  **and** shifts focus into the qty field (`.select()`'d, so the next
  digits typed replace the default "1" outright), and `Enter` from
  *either* field commits the highlighted (or top) result with whatever
  qty is currently in that field. `ArrowUp`/`ArrowDown` keeps driving
  result navigation even while focus is in the qty field (`preventDefault`
  overrides the number input's native step-up/down), since the field is
  for typing a quantity, not stepping one.
  Fourth, the biggest structural change: adding a line no longer calls
  `openExistingJob()` (full refetch + full tree rebuild) at all.
  `appendLinesToExistingBooking`'s result gained a `writtenLines` array
  (`{typeId, quantity, sectionId, lineRefId}` per successful write) so the
  frontend can build the new line's DOM node directly - name/type/class
  come from the already-loaded `state.catalogById` (the item was just
  shown as a search result), availability comes from the cache described
  above (already fetched for that same reason), so no network round-trip
  is needed to display the new line at all. The line-rendering logic
  itself was refactored into a shared `buildTreeLineNode()` (used by both
  the full-section render and this single-line insert) so there's exactly
  one implementation of what a tree line looks like. The new node is
  `appendChild`'d as the last child of its section's container, which
  places it after every existing line "for free" from DOM append order -
  satisfying "add to the end" without any explicit sort logic on the
  frontend.
  Fifth, matching persisted order to what's shown: confirmed live
  (`Sort.SortOrder` read on eqlists 10653/10655/10646) that
  `append_to_booking` assigns a coarse, heavily-tied `SortOrder` (e.g. an
  entire batch of appended lines all getting the same "2.0"), not a
  per-line rank - a new line's actual position among its section's other
  lines was whatever the SQL tie-break happened to produce, not reliably
  last. `set-line-section` now also computes `MAX("SortOrder") WHERE
  "Eqlno" = ? AND "sectionID" = ?` and sets the moved line's `SortOrder` to
  that plus 1, in the same `UPDATE` that moves it into the section -
  making "new lines sort last" durable across a future reload, not just
  true for the current in-memory DOM. Live-verified on the `Р7167МСК` test
  job (moved-then-restored a real line, confirmed the assigned SortOrder
  each step) before shipping.
  **Seamless remove, modular search, new/existing-job unification, recent
  jobs (2026-08-10, later same day)**: a large follow-up batch. (1)
  Removing a line or a section used to call `openExistingJob()` (full
  refetch + full tree rebuild), which also wiped `state.availabilityCache`
  and re-fetched every OTHER line's availability for no reason - flagged
  by the user as unnecessary load. Both now mutate state and re-render only
  what changed: `removeExistingLine` rebuilds just the affected section
  (`rerenderSectionLines`, using `loadedJob.existingLines` filtered by
  section, so a Composite's absorption re-evaluates correctly if one of
  its components was the line removed) instead of the whole tree;
  `deleteSection`'s handler removes just that section's DOM node and
  reassigns its lines into (creating, if needed) a "Без секции" bucket via
  `refreshUnsectionedBucket`. Verified live in-browser: removing a line or
  section fires only its own `DELETE` request, zero follow-up `GET
  /jobs/:ref`, and zero new `/availability` calls for any untouched line.
  (2) Extracted a generic `createSearchDropdown()` module (debounced
  search-as-you-type, `ArrowUp`/`ArrowDown` highlight with an optional
  `onHighlightChange` hook, `Enter` selects highlighted-or-top,
  `Escape`/outside-click closes, mousedown-before-blur row selection) and
  rebuilt job search, client search, and the per-section equipment search
  on it - one engine instead of three separately-written ones. Job search
  gained the same `ArrowUp`/`ArrowDown` navigation the equipment search
  already had. Also unified the dropdown container CSS (`.dropdown-results`)
  and result-row CSS (shared `.result-row`/`.highlighted`, previously
  `.section-add-result-row` duplicated the same rules under a different
  name).
  (3) **New-job mode no longer has its own separate UI/flow.** Previously
  it was a wholly different interface: name/dates/client fields, a shared
  equipment-card with its own staging table (search → add to a local list
  → edit qty inline → batch submit creates the Job+Eqlist+all-lines in one
  `POST /bookings` call). Per explicit request ("иначе это два разных
  entities... надо быть модульным и масштабируемым"), "Создать работу" now
  *only* creates the Job+Eqlist header - a new `createHiretrackJobShell`
  (`hiretrack-booking-api.ts`) + `POST /jobs` route, calling
  `initialise_new_booking` with a throwaway `placeholderTypeId` (any
  already-loaded catalog item - confirmed earlier this session that
  `initialise_new_booking`'s own embedded line never persists a `Sort` row
  regardless of what's passed, so the value has zero real effect, only
  satisfies the API's required param shape) and skipping the
  `append_to_booking` loop entirely (unlike `createHiretrackBooking`, which
  still exists unchanged for other callers, e.g. the `hiretrack-rider-match`
  skill's `create-booking.sh`). On success the frontend calls
  `setMode('existing')` then `openExistingJob(newJobRef)` - the *exact*
  same function a job-search result or a recent-job card click already
  used - so the freshly created (empty) job immediately opens in the same
  section-based tree editor as any existing job. The entire old shared
  staging-table code path (`state.lines`, `addLine`/`removeLine`/
  `renderLines`/`renderAvailabilityBadge`/`refreshAvailability`/
  `searchEquipment`, the `#equipment-card`/`#lines-table` HTML) was deleted,
  not just hidden. Verified live in-browser: filled the new-job form,
  submitted, and landed in the tree editor showing the just-created job's
  real ref/client/dates with an empty state - added a section and an
  equipment line to it successfully through the normal per-section widget.
  (4) **Recent jobs on the search page**: `Jobs.CreatedDate` (a real
  `TIMESTAMP`, confirmed live via `cur.columns()`) backs a new `job-recent`
  read op (`WHERE CreatedDate >= ?`, cutoff computed as a real `datetime`
  server-side, default 7 days) → `listRecentHiretrackJobs()` →
  `GET /jobs/recent` (registered *before* `GET /jobs/:jobRef` so "recent"
  isn't swallowed as a job ref). Shown as cards below the job search box
  whenever no job is loaded yet, styled after the Daybook (План склада)
  page's `.job` card (white card, left accent border, soft shadow, bold
  navy ref, muted meta line - card details in this session's exploration,
  no progress-bar/expand since that's Daybook-specific equipment-return
  tracking). Clicking a card opens that job the same way a search result
  does. Hidden once a job is loaded, shown again on a failed lookup (so the
  user can pick a different recent job without re-typing).
  **Back-button routing fix (2026-08-10, later same day)**: opening a job
  never actually navigated anywhere (just a `fetch` + DOM update), so no
  history entry existed for "a job is loaded" - the browser's own Back
  button fell straight through to whatever page linked into `/create-job/`
  (typically the portal), flagged by the user as wrong (should return to
  the job list, not exit the page). Fixed with plain `history.pushState`:
  `openExistingJob` now pushes a `?job=<ref>` URL on success (skipped when
  re-entering via `popstate` itself, and when the URL already points at
  that job, to avoid redundant entries from re-clicking the same result). A
  `popstate` listener re-derives the job ref from `location.search` -
  present means load that job (`pushHistory: false`, we're already at this
  URL); absent means `closeLoadedJob()` (clear `state.loadedJob`, hide the
  loaded-job view, reload the recent-jobs cards) without pushing anything
  further. Since it's a query string on the same static `index.html`,
  `express.static` serves it with no server-side route change needed, and
  the same `?job=` on a fresh page load/refresh opens that job directly
  (deep link support, previously impossible). Verified in-browser end to
  end: open a job (`history.length` +1, URL gains `?job=`) → `history.back()`
  → URL loses the param, loaded-job view hides, recent-jobs cards
  reappear, all without a page navigation → `history.forward()` re-opens
  the same job → a fresh page load at `?job=<ref>` opens it directly too.
  **Silent quantity-cap bug found and fixed (2026-08-10, later same day)**:
  user reported that changing a line's quantity above what's actually in
  stock didn't stick - looked right in the browser, but HireTrack still
  showed the old value, and a page refresh reverted the display too.
  Root-caused live by calling `change_booking_quantity` directly (bypassing
  the app) on a real line (251771, 3→13 with only 3 truly available):
  `ValidationResult: 0` (success), `WriteAction: 6`, `RequestedQty: 13`,
  but **`BookingQty: 3`** - HireTrack does not reject an over-quantity
  request, it silently *caps* the persisted amount to what's available
  while still reporting success. This is a distinct failure mode from the
  already-known "HTTP 200 even on rejection" issue (fixed 2026-08-09,
  `ValidationResult` check) - here `ValidationResult` genuinely is 0, so
  that check alone can't catch it; only comparing `BookingQty` to what was
  requested reveals the shortfall. The exact same field exists on
  `append_to_booking`'s response too (same risk on the add-new-line path,
  confirmed by inspection, not separately live-tested - the API shape is
  identical). Fixed by using `BookingQty` (not the requested value)
  everywhere a quantity gets echoed back to the UI:
  `appendLinesToExistingBooking`'s `writtenLines[].quantity` now comes from
  `result.bookingQty ?? line.quantity` (with the originally-requested value
  kept alongside as `requestedQuantity` for comparison), and the frontend's
  qty-edit and add-equipment handlers both now display the real persisted
  number immediately and show `"HireTrack применил/добавил только X из
  Y — недостаточно оборудования на складе на эти даты"` when it differs
  from what was typed, instead of showing the typed value until the next
  reload silently corrected it. Verified against a mock simulating the
  exact cap behavior for both the qty-change and add-line paths - both now
  show the correct number and message with zero further action needed
  (no reload). Real production line 251771 is unaffected (still 3, as it
  was before and after the user's own test - the capped write to 13 that
  originally exposed this never actually changed anything, since 3→3).
  **Overriding the cap entirely, per explicit follow-up instruction
  (2026-08-10, later same day)**: the fix above correctly *reported* the
  shortfall but still left the persisted quantity capped - the user then
  said plainly that stock availability doesn't matter to them at all, the
  quantity must always be exactly what they entered. Since api_v2 has no
  parameter to opt out of its own cap, added a new write op
  `force-line-quantity` (`UPDATE "Sort" SET "Quant" = ? WHERE "Lineref" = ?
  AND "Eqlno" = ?` - `Quant` confirmed live as a plain `INTEGER`, no CAST/
  BYTE quirk) called from inside both `appendToHiretrackBooking` and
  `changeHiretrackBookingQuantity` themselves, right after each api_v2
  call, whenever the returned `BookingQty` is below what was requested -
  overwrites it with the true value and returns that as `bookingQty`
  instead. Because both functions now guarantee `bookingQty === requested`
  whenever the write succeeds at all, the "HireTrack applied only X of Y"
  message from the previous fix simply stops firing on its own - no
  frontend changes needed beyond threading `eqlistId` into
  `ChangeBookingQuantityInput` (the force-write's `WHERE` clause needs it
  as a safety scope; `change_booking_quantity` itself doesn't). Explicitly
  does NOT touch `Daily`/`Price`/`PreDiscount`/`Discount`/`InvoicedTotal` -
  those stay priced for whatever quantity api_v2 actually computed before
  being overridden, so invoicing for the forced excess is not automatic
  and may need manual adjustment in HireTrack NX for billed equipment.
  Live-verified the *exact* combined flow end to end on line 251771 before
  shipping: called the real `change_booking_quantity` (3→13, capped to
  `BookingQty: 3` as before), the force-write then set it to the true 13
  (confirmed via a direct `Sort` read), then restored it to 3 - proving
  the whole detect-then-override sequence works against production, not
  just the isolated raw-SQL mechanism.
  **Section delete now deletes its equipment too (2026-08-10, later same
  day)**: the section-CRUD fix above deliberately reassigned a deleted
  section's lines to "no section" (`Sort.sectionID = NULL`) rather than
  removing them, on the assumption that was the safer default. User flagged
  this as wrong - deleting a section should delete the equipment in it, not
  orphan it into an unsectioned bucket. Fixed on the frontend: the delete
  handler now loops over every line whose `sectionId` matches (this also
  correctly picks up a Composite/Alias's absorbed component lines, since
  those are still real separate `Sort` rows in the same section - see the
  "Composite double-displayed" fix above), calling the same
  `remove_from_booking`-backed per-line DELETE endpoint the standalone "×"
  button already uses (proper delete, not a raw SQL removal), and only
  deletes the `EqSections` row itself once every line has been confirmed
  removed. If any line fails partway, the section is left in place (not
  deleted) with whatever lines already succeeded reflected in the UI, so a
  partial failure never silently loses a section along with a line still
  stuck on it. The confirm dialog now names the equipment count ("вместе с
  оборудованием в ней (N поз.)"). The `delete-section` write op's old
  `UPDATE Sort SET sectionID = NULL` stays in the Python bridge as a safety
  net only - normally there's nothing left for it to reassign by the time
  it runs, since the frontend loop already removed every line first.
  Verified in-browser against a mock server mirroring the real endpoint
  shapes: deleting a section with a plain line, a Composite parent, and its
  3 absorbed components fired 5 line DELETEs then the section DELETE, in
  that order, and removed all of it from the DOM while leaving the other
  section untouched.
  **Equipment-search badges + sales-class exclusion (2026-08-10, later same
  day)**: two related gaps in the per-section search widget
  (`buildSectionAddWidget`). (1) Search result rows only showed a name and
  an availability figure - no `typeBadgeHtml` call at all, unlike the tree
  view - so a Composite/Alias/Consumable item looked identical to a Normal
  one until it was actually added. Fixed by calling the same
  `typeBadgeHtml(item.equipmentType, item.class)` helper already used for
  tree lines. (2) `Hetype.Class` 2 (`ecNewSales`) and 3
  (`ecExRentalSales`) - stock the business sells rather than rents out -
  were never excluded from search, so sales items were selectable and
  bookable onto a job like any rental item. Fixed with a `SALES_CLASSES =
  new Set([2, 3])` filter applied in `getMatches` before the text-match
  filter, so those items never appear as a result and never trigger an
  availability fetch. Deliberately scoped to the search filter only -
  `state.catalog`/`state.catalogById` keep every item (sales-class included)
  since those are still needed for the throwaway `placeholderTypeId` used by
  new-job-shell creation and for tree-line/component badge lookups on lines
  a job may already carry. Verified in-browser against a mock catalog with
  two added sales-class items: searching "Кабель" matched all rental cable
  items with their N badge shown, and neither sales item appeared in results
  or triggered an availability call.
  **Composite component quantity wrong + duplicate-type lines vanishing
  (2026-08-11)**: two bugs reported together, root-caused to the same bug in
  the nested Composite/Alias rendering. The old code built a single
  `Map<typeId, line>` from a section's lines (last one wins on a duplicate
  key) to find each declared component's real Sort row, and hid every line
  whose typeId appeared anywhere in that map as a component - so a section
  containing two real lines of the same type (one genuinely the Composite's
  own component, one an unrelated separate booking of the same equipment)
  picked an arbitrary one for the nested quantity and silently dropped the
  other from the tree entirely. Confirmed live against production: type
  623's recipe is 2x`569` (EK2000) + 1x`605` (SR2050); a real Job (Eqlist 22,
  composite booked qty 4) has the correctly-generated component rows
  (569x8, 605x4 - exactly recipe x qty) but ALSO an unrelated standalone 569
  line (qty 2) sitting in the same section - the old Map picked whichever of
  the two 569 lines it iterated last, sometimes showing the wrong nested
  quantity and always hiding the other one. Checked across all 183 real
  type-623 bookings in production: 175 have exactly one quantity-exact match
  per component (`component.quantity * this composite's own booked qty`),
  only 8 are ambiguous. `Sort` has no DB-level link between a Composite's
  own row and its component rows (confirmed against `db.sql`'s schema - no
  MasterLineRef-style column), so exact-quantity match is the only usable
  signal.
  Fixed with `computeComponentMatches(sectionLines)`: for each
  Composite/Alias line, claims at most one sibling line per declared
  component - only when its quantity exactly equals the expected count -
  and returns a per-line `Map<componentTypeId, matchedLine|null>` plus the
  set of claimed line objects (not typeIds) to skip when rendering
  standalone rows. An ambiguous component (no exact match) now falls back to
  the catalog recipe's own number (`component.quantity * this line's own
  qty` - previously the fallback never multiplied by the composite's own
  booked qty at all, always showing the bare per-unit recipe number) and
  leaves every real line of that type visible as its own row, instead of
  guessing wrong and hiding data. Applied consistently in the three places
  that used to build their own ad hoc `linesByType` map: full section
  render, the single-section seamless re-render (line remove/qty edit), and
  the seamless single-line insert. Verified in-browser against a mock
  reproducing the exact production scenario (composite 623 qty 4, a
  correctly-matching 569/605 pair, plus a stray unrelated 569 line, plus two
  separate identical standalone lines of another type): nested view showed
  8xEK2000/4xSR2050 (not the wrong number), the stray 569 line rendered on
  its own, both duplicate standalone lines rendered separately, and deleting
  one of the two duplicates left the other one untouched in the tree.

## Roadmap (2026-08-11)

User handed over a backlog of 15 further `/create-job/` items, analyzed and
grouped into phases (bug fixes -> job-header completeness -> multi-Eqlist
creation -> UI polish -> bigger analytical features). Phase 0 shipped this
session:

  **Phase 0 - Eqlist title bug + multi-Eqlist display (2026-08-11)**: two
  confirmed-live bugs, fixed together since both touch `hiretrack-job-lookup.ts`/
  the existing-job load path.
  (1) **Eqlist title**: `CreateNewEqlist` (`db.sql:9143-9144`, the stored
  function behind `initialise_new_booking`) always sets `Eqlists.Eql_Title`
  itself to `Job_Title || ':' || Eql_name` (the short auto-generated
  reference code, e.g. "5150 @ 10.08.2026:Р7170МСКАРНД01МСК") with no
  parameter anywhere in `api_v2` to opt out - confirmed live across all 15
  Eqlists created through `/create-job/` before this fix, every one showed
  this redundant, ugly title. `Eql_name` itself (the short code) is a
  separate field, left untouched - it follows the same auto-numbered
  convention as `Job_Ref` and isn't what's shown as the list's name.
  Fixed with a new write op `update-eqlist-title`
  (`UPDATE "Eqlists" SET "Eql_Title" = ? WHERE "Eql_no" = ?`) called right
  after `initialise_new_booking` on both job-creation paths
  (`createHiretrackJobShell` for `/create-job/`, and `createHiretrackBooking`
  for the `hiretrack-rider-match` skill's `create-booking.sh`), setting it
  to the clean job name. Live-verified twice: (a) an isolated write/restore
  on a real Eqlist (10650) confirmed the raw SQL works cleanly, no
  NexusDB quirks for this plain `SHORTSTRING(30)`-adjacent `Eql_Title`
  field; (b) a full end-to-end call to the deployed `createHiretrackJobShell`
  (bypassing HTTP/auth by requiring the compiled service module directly
  with the service's own env vars, same pattern as other live verifications
  this session) created a real Job/Eqlist and confirmed `Eql_Title` came
  back exactly `"CLAUDE TITLE FIX TEST - DELETE ME"` - no `:AutoCode` suffix.
  Left under Test client for manual cleanup (no `delete_job` action exists
  in `api_v2` - confirmed live, `"No item found with name \"delete_job\""` -
  so the earlier session's own note about a job being "cleanly deleted via
  delete_job" must have meant something else, not a real reusable action;
  raw multi-table cascade delete wasn't attempted to avoid touching
  `EqSections`/`Sort` without an established safe pattern for it).
  (2) **Multi-Eqlist display**: `openExistingJob` hard-coded
  `job.eqlists[0]`, even though `hiretrack-job-lookup.ts` already returned
  every Eqlist on the job - every Eqlist past the first was silently
  invisible. Confirmed live this is a common, real production pattern (one
  job has 27 separate Eqlists, one per act on a multi-day booking; 1386
  jobs in production have more than one). Fixed with an Eqlist picker
  (`<select>`, shown only when a job has more than one Eqlist - the common
  single-Eqlist case is visually unchanged) that switches the whole
  ref/client/dates/tree view between them via a new `applyEqlist(job,
  eqlist)` helper, labeled with the now-fixed `Eql_Title` + a compact date
  range. `JOB_LOOKUP_EQLISTS_QUERY` extended to also select `Eql_Title`
  (surfaced as `eqlistTitle`) and explicitly `ORDER BY Eql_no` so the
  picker's option order is stable. Switching resets the availability
  cache (a different Eqlist almost always means a different date range).
  Verified in-browser against a mock 3-Eqlist job (mirroring the real
  27-Eqlist production example): picker listed all three with clean
  labels, switching correctly swapped dates/section/lines for each,
  and the single-Eqlist case still hides the picker entirely (no
  regression). Deployed to production (`feature/api-v2-availability-booking`,
  commit `a10a702`), service restarted healthy.
  **Remaining phases not yet started**: Phase 1 (default times per HireTrack
  settings, default job type "Аренда", Sales Person/Handler
  auto-set+picker, contact-person picker, default section name), Phase 2
  (creating additional Eqlists on an existing job, building on this
  session's display fix), Phase 3 (rectangular recent-job cards), Phase 4
  (equipment occupancy table modeled on Crew Bookings, shortage-only jobs
  view, jobs Gantt, accessory suggestions + Reminders). See the chat
  history for the full phase breakdown and reasoning; not duplicated here
  to avoid this doc drifting out of sync with the live discussion.

  **Phase 1 shipped (2026-08-11, same session)**: default job-header fields,
  all confirmed missing/investigated live before implementing.
  `api_v2`'s `initialise_new_booking` never sets `Jobs.Type`/`Handler`/
  `SalesPerson` at all - confirmed by reading its params (only `job_name`
  reaches `Jobs`, via `CreateNewEqlist`'s own `Job_Title` lookup) and by
  checking real jobs (all NULL). All three are plain `Jobs` columns with no
  pricing/stored-function entanglement (`Type` -> `jobtypes.Type_idx`,
  `Handler`/`SalesPerson` -> `Users.UID`), so a direct `UPDATE` is safe -
  new write op `update-job-header` (only sets whichever of the three fields
  is actually passed), called right after the title/dates fixes in both
  `createHiretrackJobShell` and `createHiretrackBooking`. `jobtypes.Type_idx
  = 2` is "Аренда" (confirmed live) and is now always set. `Handler` always
  defaults to `FALLBACK_USER_ID` (no picker for it yet - this app is
  PIN-gated shared access with no per-user login, so there's no "current
  user" concept to default to instead). `SalesPerson` defaults to the same
  fallback but now has an explicit picker (`<select>`, populated from
  `Users` filtered to `Active=TRUE AND IsCrew=FALSE`) on the new-job form.
  **Default dates**: HireTrack NX's own "Jobs > Defaults" settings live in
  the `Rules` table (confirmed live per-site: Site 1 has
  `DefaultJobStartTime=14:00:00`, `DefaultJobEndTime=12:00:00`,
  `DefaultJobPeriod=2`) - read live via a new `job-defaults` op (not
  hardcoded, so a later admin change in HireTrack NX is picked up without a
  redeploy) and exposed through `GET /api/create-job/form-options`. The
  date-from field now pre-fills to "today at DefaultJobStartTime" instead
  of starting empty; date-to recomputes from date-from + DefaultJobPeriod at
  DefaultJobEndTime every time date-from changes, until the user directly
  edits date-to themselves (tracked via a `dateToManuallyEdited` flag set
  only by a real `input` event, since programmatic `.value` writes don't
  fire one). Matches the "start = date + Default Job Start Time, end =
  start + Default Job Period + Default Job End Time" convention noted
  earlier this session from the user's own description of HireTrack's UI.
  **Contact person**: found the `CONTACTS` table (`Company`, `Person` ->
  `Name2`, `xLink` = JobNo, `RecordType='ctJobs'`) - confirmed live it has
  no "company address book" concept of its own, HireTrack NX creates a
  fresh row per job even when it's really the same real `Name2` person
  being reused (the same `Person` id recurs across many `CONTACTS` rows
  with different `xLink`). New read op `client-contacts` dedupes by
  `Person` to list people previously linked to a given client Company; a
  picker appears on the new-job form only once a client with such history
  is selected (empty for a brand-new client, by design - no "create a new
  contact" flow yet, out of scope for this pass). New write op
  `add-job-contact` inserts a fresh `CONTACTS` row for the new job when a
  contact is picked. **Default section name**: the existing "+ Добавить
  секцию" control now pre-fills `Секция N` (N = current section count + 1)
  instead of requiring the user to type a name before Enter/click works.
  Both new write ops (`update-job-header`, `add-job-contact`) live-verified
  through the real write bridge script (not just raw SQL) against a
  throwaway test job before wiring into the app; the full combined flow was
  then verified end-to-end against the deployed production service
  (bypassing HTTP/auth by requiring the compiled service module directly,
  same pattern as Phase 0's verification) - `Jobs.Type/Handler/SalesPerson`
  and the `CONTACTS` row all came back exactly as expected. Also fixed a
  latent serialization bug found along the way: the read bridge's
  `serialize()` only handled `datetime`/`date` values, not `datetime.time`
  (`Rules.DefaultJobStartTime`/`EndTime` are `TIME` columns) - would have
  crashed `json.dump` with "Object of type time is not JSON serializable"
  the first time `job-defaults` actually ran. Frontend UI verified in-browser
  against a mock server: date fields pre-filled correctly, Sales Person
  list populated, contact picker appeared only for a client with mocked
  history and stayed hidden for one without, default section name computed
  correctly against a job carrying 3 existing sections. Deployed to
  production (`feature/api-v2-availability-booking`, commit `bfc216e`),
  service restarted healthy.

  **Phase 2 shipped (2026-08-11, same session)**: creating a further Eqlist
  on an already-existing job, plus a skeleton for editing an Eqlist's own
  dates after creation - user flagged mid-phase that Eqlists on the same
  job can genuinely run on different dates from the job's own ("project")
  dates, so both needed to be independently addressable, not just set once
  at creation.
  `api_v2` has no action at all for "add an Eqlist to an existing job" -
  `initialise_new_booking` only ever creates a brand-new Job. Found the
  underlying stored function it calls internally, `CreateNewEqlist`
  (`db.sql:9015`), and called it directly via the writable DSN
  (`{CALL CreateNewEqlist(aJobNo, aStartDate, aEndDate, aStatus=1,
  aListType=0, aSourceWarehouse=0, aDestWarehouse=0, aBorrowingList=0,
  aEqlistClass=0)}`) - new write op `create-eqlist`. Its own doc comment
  says `aStatus`: "-1 for real jobs", but live-testing showed that literally
  stores `Defcon=-1` (not a valid resolved status - real Eqlists show
  `Defcon=1`, matching `Rules.DefaultEqlistStatus`), so `1` is passed
  instead. **Its `LASTAUTOINC` can't be trusted** the way every other
  `CreateNew*`-style write in this bridge relies on it (`CreateNewNote`,
  `EqSections` inserts): confirmed live that reading `LASTAUTOINC` right
  after the `{CALL ...}` returns an unrelated value (429551 - no such
  `Eql_no` ever existed), because the function does several of its own
  internal autoinc-generating inserts before it returns. Fixed by querying
  "most recently created Eqlist for this Job" (`ORDER BY CreatedDate DESC`)
  instead - confirmed reliable for this app's usage pattern (single
  PIN-gated tool, no realistic concurrent-creation-on-the-same-job race).
  Applies the same `Eql_Title` "Title:AutoCode" cleanup as the job's own
  first Eqlist (confirmed the new Eqlist gets the identical bug).
  **Date defaults, per the user's explicit follow-up**: `Jobs."Due Out"`/
  `"Due Back"` is a genuine job-level date range, confirmed live to be
  distinct from and NOT kept in sync with any individual Eqlist's own dates
  (`CreateNewEqlist` copies the FIRST Eqlist's dates onto it when a job is
  first created, but never touches it again for later Eqlists - a real
  27-Eqlist job's `Due Back` still matched only its first Eqlist's end
  date, weeks before the actual last one). `JOB_LOOKUP_QUERY` extended to
  select it; the "+ Добавить список" form pre-fills both date fields from
  it (falling back to the currently-shown Eqlist's own dates if the job has
  none) but leaves them fully editable before submitting.
  **Dates-edit skeleton**: `update-eqlist-dates` already existed
  (used internally for the third-bug fix and legacy-job self-heal) but was
  never exposed via a route - added `PUT
  /jobs/:jobRef/eqlists/:eqlistId/dates` and a pencil-icon UI next to the
  loaded Eqlist's dates readout, matching the existing section-rename UX
  pattern. Deliberately **disabled once the Eqlist has real lines** -
  changing header dates on a populated list isn't safe yet, since existing
  lines' own `Sort.D1`/`D2` aren't updated to match, and any future append
  would then fail HireTrack's exact-date match (the same mechanism behind
  the third and fourth bugs fixed earlier this session) - a genuine
  "skeleton for the future" as the user put it, not a complete feature;
  reconciling existing lines' dates on an edit is deferred. A real
  correctness bug was caught and fixed during in-browser verification:
  saving new dates updated the live view but not the cached Eqlist-picker
  list, so switching to a different Eqlist and back without a full reload
  would have reverted the display to the pre-edit dates - fixed by also
  updating `state.loadedJobEqlists`' matching entry and its `<option>` text
  on a successful save.
  Both new write ops verified live end-to-end against the deployed
  production service before wiring into the UI (create then immediately
  re-date a real new Eqlist on the `Р7179МСК` test job, confirmed via a
  direct `Sort`/`Eqlists` read: correct title, correct final dates, correct
  `Defcon`). Frontend verified in-browser: default dates matched the mock
  job's own `dueOut`/`dueBack` exactly, the picker and tree correctly
  switched to a freshly created Eqlist, the pencil button was disabled for
  a populated Eqlist and enabled for an empty one, and the switch-away-and-
  back cache bug was caught and fixed before shipping. Deployed to
  production (`feature/api-v2-availability-booking`, commit `2f402a0`),
  service restarted healthy.

  **Availability badges getting permanently stuck on large jobs, fixed
  (2026-08-11, same session)**: user reported that on a real job (Eqlist
  6807, 122 lines / 120 distinct equipment types), availability "just
  stops updating" at some point. Root-caused live: HireTrack's own `api_v2`
  gateway enforces a **global concurrency cap of its own** - firing all 120
  of that job's `check_availability` calls concurrently (the tree does one
  per distinct type, with zero throttling anywhere) got 112 of them back as
  HTTP 503 `{"error":"Service temporarily unavailable","current_load":10,
  "max_capacity":10,"retry_after":5}` the moment more than 10 were in
  flight - and nothing anywhere retried them, so those lines' badges were
  left on "?" permanently. This cap is global across everything hitting the
  gateway (not per browser tab), so throttling only in the frontend
  wouldn't be enough if multiple tabs/users were active at once - fixed
  server-side instead, where one Node process funnels all of this app's
  `api_v2` traffic. Added a simple counting-semaphore `ConcurrencyLimiter`
  (capped at 4, well under the gateway's 10, leaving headroom for other
  concurrent traffic - booking writes, other sessions) wrapping
  `checkHiretrackAvailability`'s outbound call, plus a retry-on-503 helper
  that honors the gateway's own `retry_after` hint (falls back to 1s if
  absent). `requestJson`'s rejected `Error` was changed to a new
  `HiretrackHttpError` subclass carrying the real status code + parsed body
  (previously only stringified into the message), so the retry logic can
  distinguish "worth retrying" from any other failure without string
  parsing. Also skips fetching entirely for a line whose `Sort.Type` is
  NULL (confirmed live: one row on this exact job) instead of burning a
  queue slot on a request guaranteed to fail (HTTP 422, "'null' is not a
  valid integer value"). Verified live end-to-end, twice: (1) the unfixed
  code reproducibly failed 112/121 concurrent requests against this real
  job; (2) the fixed code (compiled and run directly against production,
  same technique as other live verifications this session) succeeded on
  all 120 (excluding the null-type row), at a cost of ~45s total load time
  for this specific 120-type job - an explicit, reasonable tradeoff over
  silently-wrong/stuck data. **Noted as a follow-up, not implemented now**:
  `check_availability` itself is inherently slow (observed 800ms-4s per
  call even with zero contention), so a very large job will always take a
  while to fully populate regardless of this fix; lazy-loading availability
  only for visible/expanded sections (e.g. via `IntersectionObserver`)
  would meaningfully cut the burst size for huge jobs and is worth
  considering separately if this becomes a recurring pain point. Deployed
  to production (`feature/api-v2-availability-booking`, commit `7f60eec`),
  service restarted healthy.
