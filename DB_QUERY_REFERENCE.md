# HireTrack DB Query Reference

Source of truth for database relationships used in this integration:

- primary source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql)
- secondary sources for field descriptions only:
  - [all.csv](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/all.csv)
  - [hiretracknx_schema_full.html](/C:/Users/shpar/Downloads/hiretracknx_schema_full.html)

Rule:

- trust `db.sql` foreign keys first
- use `all.csv` and `hiretracknx_schema_full.html` only for field meaning and domain grouping
- if a field description conflicts with DDL, trust the DDL

## Scope

This is the **general, cross-project reference** for HireTrack's schema and query
behavior — not tied to any one integration. Individual project docs (e.g.
`EQUIPMENT_CATALOG_MATCH_BLUEPRINT.md` for the rider-matching feature) should
link back here for schema/driver facts instead of re-explaining them, and
should stay focused on their own feature-specific design.

Domains currently covered:

- `jobs.general`
- `finance`
- `personnel` (basic) / `personnel.crew_scheduling` (full Enhanced-Crewing chain — see below)
- `transport`
- `equipment_catalog` (`Hetype`/`category`, plus how equipment types relate to
  each other — see below)

## Core Identity

Main integration key:

- `JOBS.JobNo`

Human-readable reference:

- `JOBS.Job_Ref`

Primary table:

- `JOBS` at [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:5441)

`Jobs.CreatedDate` (TIMESTAMP, confirmed live via `cur.columns(table='Jobs')`,
2026-08-10) is the row's actual creation timestamp - used for a "recently
created jobs" list (`WHERE CreatedDate >= ?`, cutoff bound as a real
`datetime`, not a string). Distinct from `ModifiedDate` (last edit) and from
`"Due Out"`/`"Due Back"` (the job's own rental period, unrelated to when the
record was created). `CreatedBy`/`ModifiedBy`/`ConfirmedBy` are all
`users.uid` FKs.

## Status Codes (`defcon` lookup)

`JOBS.Status`, `Crew.xStatus`, `Crew_header.xStatus`, and `EQLISTS.Defcon` all
point at the same shared lookup table, `defcon.Defcon_idx` (`SMALLINT`, signed
— negative codes exist). Confirmed live 2026-08-07 by reading the table
directly (no need to guess from sample job titles):

| `Defcon_idx` | `Defcon_text` | Notes |
|---|---|---|
| -3 | Завершено | `System=False` |
| -2 | Ignore | `System=False`, internal/hidden marker |
| -1 | Отмена | Cancelled |
| 0 | Disregard | `System=True` |
| 1 | Запрос | Quote/enquiry stage |
| 2 | Бронь | Provisional booking |
| 3 | Подтверждено | Confirmed |
| 4 | В работе | In progress |
| 5 | Завершено | `System=False`, distinct row from -3 (different `SortOrder`) |
| 6 | Подтвержден (внутренний) | Internal-confirmed variant |

`Defcon_text` for -3 and 5 both display as "Завершено" but are different rows
(`SortOrder` 5 vs 7) — don't assume the text is unique per code.

## Confirmed Foreign Keys

### jobs.general

- `JOBS.Client -> Company.CompanyCounter`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:5576)
- `JOBS.Type -> jobtypes.Type_idx`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:5578)
- `JOBS.PrimarySite -> Sites.IDX`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:5581)
- `JOBS.Handler -> Users.UID`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:5585)
- `JOBS.CreatedBy -> Users.UID`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:5588)
- `JOBS.SalesPerson -> Users.UID`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:5591)
- `JOBS.Status -> defcon.Defcon_idx`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:5594)
- `JOBS.xCrewManager -> Name2.NameCounter`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:5597)
- `JOBS.xCrewCoordinator -> Company.CompanyCounter`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:5600)

### project layer

- `Projjob.xProject -> Project.Idx`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:5620)
- `Projjob.xJob -> JOBS.JobNo`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:5623)

### venue and company

- `venue.Company -> Company.CompanyCounter`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:5977)

### personnel

- `Crew.Header -> Crew_header.Idx`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:1440)
- `Crew.Type -> CREWTYPE.Crewindex`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:1444)
- `Crew.xCrewTask -> CrewTasks.IDX`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:1447)
- `Crew.xStatus -> defcon.Defcon_idx`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:1450)
- `CrewPositions.xCrewRequest -> Crew.Idx`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:2925)
- `CrewPositions.xPerson -> Name2.NameCounter`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:2928)
- `CrewShifts.xPosition -> CrewPositions.IDX`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:2973)
- `CrewAccommodation.xJob -> JOBS.JobNo`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:2416)

### personnel.crew_scheduling — full chain (confirmed live 2026-08-07, read-only)

Traced end-to-end against a real job (`JOBS.Job_Ref = 'Р6976МСК'`, note the
**Cyrillic Р**, not Latin `P` — every `Job_Ref` uses it) and cross-checked
name/role/count against the HireTrack NX client's own crew grid, 100% match:

```
JOBS (JobNo, Job_Ref, Job_Title, "Due Out"/"Due Back", Status->defcon,
      xCrewManager->Name2 = Crew Boss, xCrewCoordinator, NewCrewing)
  -> Crew_header   (Idx, XJob->JOBS.JobNo, Title = phase name e.g. "Обслуживание",
                     "Function"->Crew_Function.Idx, xStatus->defcon)
     -> Crew        (Idx, Header->Crew_header, Type->CREWTYPE.Crewindex = role name,
                      "Out"/"Back", Quantity, Allocated)
        -> CrewPositions (IDX, xCrewRequest->Crew.Idx, xPerson->Name2.NameCounter
                           [NULL = unassigned], Status (BYTE, cast!), Description
                           = "Position #2" etc. for extra slots on the same request)
           -> CrewShifts (IDX, xPosition->CrewPositions.IDX,
                           xActivity->CrewActivities.IDX, BookingState/Status/
                           OrderStatus/ShiftType — all BYTE, cast!)
              -> CrewActivities (IDX, xArea->Crew_header.Idx, ActivityDate,
                                 ActivityType (BYTE), Description = "Day N")
Name2 (NameCounter PK, FullName/FORENAME/SURNAME, CREW bool = crew-eligible,
       Archived, Hold) — people
CREWTYPE (Crewindex PK, CrewText) — role display names
Crew_Function (Idx PK, "Function") — phase/area category names (separate from
  Crew_header.Title, which is the actual free-text phase label shown in the UI)
```

**The filter for "unassigned personnel" the whole tool is built around:**
`CrewPositions.xPerson IS NULL` (equivalently `CAST(CrewPositions.Status AS
SMALLINT) = 0`, i.e. `ssUnprocessed` — see enum table below, both agree in
every case checked so far).

#### Enhanced-Crewing enum fields (decoded from live `"#Fields".FIELD_DESC` —
Pascal `TSomeEnum = (member0, member1, ...)`, ordinal = position, **0-based**)

All of these are `BYTE` columns — always `CAST(col AS SMALLINT)`, see driver
quirks below, or you get garbage.

| Field | Delphi type | Values (ordinal = list position) |
|---|---|---|
| `CrewPositions.Status`, `CrewShifts.Status` | `TShiftStatus` | 0 ssUnprocessed, 1 ssInProgress, 2 ssPencilled, 3 ssBooked |
| `CrewPositions.OrderStatus` | `TPositionOrderStatus` | 0 posNotRequired, 1 posOutstandingNone, 2 posOutstandingSome, 3 posFullfilled |
| `CrewShifts.OrderStatus`, `CrewAccommodation.OrderStatus` | `TShiftOrderStatus` | 0 sosNone, 1 sosPartial, 2 sosFullfilled, 3 sosOver |
| `CrewShifts.BookingState` | `TShiftBookingState` | 0 sbsIncQuote, 1 sbsExcQuote, 2 sbsCancelled, 3 sbsBlackout |
| `CrewShifts.ShiftType` | `TShiftType` | 0 stUnknown, 1 stNormal, 2 stBlackout |
| `CrewShifts.AccommodationStatus` | `TAccommodationStatus` | 0 asNotRequired, 1 asClientProvides, 2 asWeProvide |
| `CrewActivities.ActivityType` | `TActivityType` | 0 atOnSite, 1 atWarehouse — constant `0` on every row seen so far |
| `CrewPositionOffers.OfferStatus` | `TCrewOfferStatus` | 0 cosShortlisted, 1 cosContacted, 2 cosUnavailable, 3 cosPossiblyAvailablity, 4 cosAvailable, 5 cosRejected, 6 cosPencille[d?] (name truncated in FIELD_DESC, re-check live if this one matters) |
| `Crew.RecType` | `TCrewRecordType` | 0 crtOld, 1 crtUpgrading, 2 crtUpgraded, 3 crtNew |
| `Crew.TaskRepeatOptions` | `TTaskRepeatOptions` | 0 troNever, 1 troDaily, 2 troWeekly, 3 troMonthly, 4 troAnnually |
| `Crew.TaskRepeatEndType` | `TTaskRepeatEndType` | 0 tretNever, 1 tretAfterDate, 2 tretAfterOccurrences |
| `JOBS.InvoiceState` | `TJobInvoiceState` | 0 jisNothingToInvoice, 1 jisDoNotInvoice, 2 jisNothingInvoicedYet, 3 jisPartiallyInvoiced, 4 jisFullyInvoiced |
| `JOBS.JobVisibility` | `TJobVisibility` | 0 jvEverywhere, 1 jvNotInSearches |
| `Name2.xRecordStatus` | `TRecordStatus` | 0 rsIntended, 1 rsPending, 2 rsAccepted, 3 rsDeleted |
| `CrewTasks.Status` | also called `TRecordStatus` in `FIELD_DESC` but a **different** member list — 0 rsAny, 1 ctsLegacy, 2 ctsNew, 3 ctsRetired (don't reuse the `Name2.xRecordStatus` mapping here) |
| `Name2.TransactVia` | `TCrewTransVia` | 0 ctvPerson, 1 ctvPersonAsCompany, 2 ctvAgency, 3 ctvInHouse |
| `CrewAffinities.LinkType` | `TAffinityLinkType` | 0 altHandler, 1 altCrewBoss |
| `CrewAccommodation.Flag` | `TAccommodationFlag` | 0 afNone, 1 afShiftDateChange, 2 afShiftRoomChange |
| `CrewAccommodationLkp.AccommodationDay` | `TAccommodationDay` | 0 adBeforeShift, 1 adOnShift, 2 adAfterShift |
| `CREWTYPE.CrewPayRateCompare` | `TCrewPayRateCompare` | 0 cprcHourly, 1 cprcDaily |
| `CrewTasks.TaskType` | `TCrewTaskType` | 0 cttUnassigned, 1 cttUnavailable |

Verified live against the traced job: all 5 real assigned `CrewPositions` rows
→ `Status=3` (`ssBooked`), the 1 unassigned row → `Status=0` (`ssUnprocessed`,
`xPerson=NULL`) — the two unassigned signals agree.

### transport and equipment

- `EQLISTS.Job_no -> JOBS.JobNo`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:6548)
- `EQLISTS.Venue_no -> Company.CompanyCounter`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:6545)
- `EQLISTS.Defcon -> defcon.Defcon_idx`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:6551)
- `Hetype.Category -> category.Category`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:4213)
- `Sort.Eqlno -> EQLISTS.Eql_no` (equipment list line items)
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:6608)
- `Hetype.xSimilar -> Similars.IDX` (functional taxonomy grouping — see below)
- `related.Mastertype/Subtype -> Hetype.Type` (accessories — see below)
- `COMPOSIT.Mastertype/Componenttype -> Hetype.Type` (kit recipes — see below)

**`Hetype.xManufacturer -> Company.CompanyCounter` and `Hetype.MPN` exist as a
confirmed FK/field, but do NOT use them as brand/model of the equipment.**
Confirmed directly by the business owner: in this HireTrack setup those two
fields record the *supplier / where the item was purchased*, not the
equipment's actual brand or model. Brand/model text lives inside
`Hetype.Description` as free text (e.g. "d&b V8", "Shure SM58"). Don't
reintroduce a `Company` join for "manufacturer" here.

### equipment_catalog: how equipment types relate to each other

Beyond the plain `Hetype`/`category` pair, four more things shape how a
"type" of equipment should be read and matched:

- **`Hetype.EquipmentType`** (`BYTE`) is `TEquipmentType = (etSimple,
  etCompositeKit, etAliasKit, etPricedAliasKit, etMarkup)`
  (`db.sql:20747`) — `0`=plain item, `1`=Composite Kit, `2`/`3`=Alias/Priced
  Alias Kit (a pre-bundled system/package), `4`=markup-only line. Live
  distribution: 2203/85/9/11. A rider/order line that describes a "pair",
  "system", or "package" often already exists as one of these bundled types
  — check before assembling components by hand.
- **`Hetype.Class`** (`BYTE`, needs `CAST(... AS SMALLINT)`) is a
  *separate* axis from `EquipmentType`: `TEquipmentClass = (ecRental,
  ecConsumable, ecNewSales, ecExRentalSales)` — `0`=rental stock (the
  normal case), `1`=consumable, `2`=new sales, `3`=ex-rental sales.
  Confirmed live via `"#Fields"."FIELD_DESC"` (`TABLE_NAME`/`FIELD_NAME`
  columns, not `"Table Name"`/`"Field Name"`) for `Hetype`/`Class` =
  `"ecRental, ecConsumable, ecNewSales,ecExRentalSales (0..3)"`,
  cross-checked against live distinct-value counts: 0→1906, 1→186, 2→75,
  3→142. Used by `stocktakes-app`'s create-job page to badge Consumable
  lines distinctly from Normal ones (2026-08-10).
- **`Similars`** (`db.sql:4114`, `IDX`/`Name`) + `Hetype.xSimilar` group
  equipment into a curated ~48-category functional taxonomy — e.g. "Микрофон
  вокальный" (13 members), "Дибокс" (15), "Тарелка крэш" (30), "Рэк том"
  (22), "Стойка для хай-хета" (16). These names are how people actually
  describe equipment ("vocal mic", "DI box") and are a much cleaner match
  target than raw `Hetype.Description` text. Not every `Hetype` row has an
  `xSimilar` set.
- **`related`** (`db.sql:4239`): `Mastertype -> Subtype` (both FK
  `Hetype.Type`), `Quantity`, `Required` (mandatory vs optional accessory
  flag), `Charge`, `Ratio1/Ratio2`. Confirmed live: `Type 405` (Yamaha CL5)
  -> `Type 254` (iPad, optional); `Type 83` (L-acoustics X15 HiQ) -> 6
  optional mounting accessories. 708 rows / 252 distinct master types.
- **`COMPOSIT`** (`db.sql:2179`): `Mastertype -> Componenttype`, `Quantity`,
  `NoAutoCountOut` — the pre-booking "recipe" for a Composite/Alias
  `Hetype` (found via the NX client's own "Composite Definition" tab).
  Confirmed live: `Type 33` "Zildjian A Custom 14\" Hi-Hats" -> exactly
  `Type 21` (Bottom) x1 + `Type 22` (Top) x1. 217 rows / 77 distinct master
  types. `SyncCompositeDefinition` and friends (`db.sql:15381`) only operate
  on already-*booked* `Sort` lines (parent/child via `RecType` 10/11 and
  `LineCode`) — irrelevant for reading a type's definition before booking.

Neither `related` nor `COMPOSIT` are covered by `Lookups_LOG` (the `HeType`
change-feed trigger `trHeType_LOG`, `db.sql:20699`) — a delta sync keyed off
that log only catches changes to a master `Hetype` row itself, not standalone
edits to its `related`/`COMPOSIT` rows. Acceptable in practice (these tables
change rarely), but don't assume they're always fresh off a delta-only sync.

### Writing to HireTrack — two confirmed-safe patterns, one confirmed-dangerous one

**Don't write to `Sort`/`EQLISTS` casually.** It's entangled with pricing,
discounts, sections, and invoicing. That said, a correct direct write *is*
now confirmed to work (see below) — the danger is doing it *incorrectly*
against real production data, not the act of writing itself.

**1. Note (`Notebook`/`notebookdetails`) — the safe default for "just record
equipment against something", no live job needed.**
`notebookdetails` has no pricing/invoice entanglement, so a plain `INSERT` is
fine. `NoteBook.Title` is `varchar(50)` — longer titles fail with a field-width
error, not truncation. `notebookdetails` has three price columns
(`ListUnitPrice`, `AgreedUnitPrice`, `LinePrice` = `Qty × unit price`) — set
all three, not just one, or the NX client shows price 0.
```sql
-- master row: CreateNewNote (data-modifying function - see ODBC CALL note below)
{CALL CreateNewNote(?title, ?user, ?site, ?currency, ?priceScheme)}
SELECT LASTAUTOINC FROM #dummy  -- new note id
-- detail row (plain insert, safe):
INSERT INTO notebookdetails (xnote, qty, eqtype, listunitprice, agreedunitprice, lineprice, rectype, warehouse, xcategory)
VALUES (?, ?, ?, ?, ?, ?, 1, 1, (SELECT TOP 1 category FROM hetype WHERE type = ?));
```

**2. Direct `Sort` insert into a live Eqlist — works, confirmed live, but has
one non-obvious requirement: `Sort.sectionID` must point at a real
`EqSections` row, never `NULL`.** A line with `sectionID = NULL` inserts fine
with fully correct data (price, qty, dates) but is **invisible in the NX
client**. Fix: insert an `EqSections` row first (or reuse an existing
`sectionID` on that Eqlist) and point the line at it.
```sql
-- 1. section (skip if reusing an existing sectionID)
INSERT INTO EqSections (SectionText, xEqlno, sortOrder) VALUES (?, ?, ?);
-- new idx via: SELECT LASTAUTOINC FROM #dummy
-- Full EqSections column list (confirmed live via cur.columns(), 2026-08-10):
-- idx INTEGER (LASTAUTOINC, same pattern as CreateNewNote), SectionText CHAR(255),
-- xEqlno INTEGER, sortOrder FLOAT (not an int - existing rows use 1.0, 2.0, ...;
-- append a new section with MAX(sortOrder)+1), xSectionType WORD, xSectionCategory
-- INTEGER, Budget MONEY, Notes TEXT - all nullable except what you supply, so a
-- plain 3-column insert (xEqlno/SectionText/sortOrder) is enough. Rename is a plain
-- UPDATE EqSections SET SectionText = ? WHERE idx = ?. Delete: Sort.sectionID
-- accepts NULL (confirmed live) - UPDATE Sort SET sectionID = NULL WHERE
-- sectionID = ? AND Eqlno = ? before DELETE FROM EqSections WHERE idx = ?, so
-- lines in a deleted section land in "no section" instead of pointing at a
-- vanished row. All three verified live on a throwaway section on Eqlist 10653
-- (Р7167МСК test job) before shipping - created, renamed, then cleanly deleted.
-- Moving an EXISTING line to a different section (also just a plain UPDATE,
-- confirmed live 2026-08-10 - moved a real line then moved it back):
-- UPDATE Sort SET sectionID = ? WHERE Lineref = ? AND Eqlno = ?;
-- Needed because api_v2's append_to_booking has no section parameter at all -
-- a freshly appended line lands wherever HireTrack itself decides (observed
-- live: an auto-created "Warehouse Added Equipment" section), so moving it
-- into the right section is always a separate follow-up write, never part of
-- the append call itself.
-- Sort.SortOrder (FLOAT, like EqSections.sortOrder) is what orders lines
-- within a section - confirmed live (2026-08-10, read across eqlists
-- 10653/10655/10646) that append_to_booking assigns a coarse, heavily-tied
-- value (e.g. every line in one appended batch getting the same "2.0"), not
-- a per-line rank - so a fresh line's actual position among its section's
-- other lines is whatever the SQL tie-break happens to produce, not
-- reliably last. To make "new lines go to the end" durable, set-line-section
-- also does UPDATE Sort SET SortOrder = (SELECT MAX(SortOrder) FROM Sort
-- WHERE Eqlno = ? AND sectionID = ?) + 1 WHERE Lineref = ? AND Eqlno = ? in
-- the same statement that moves the line into its target section.

-- 2. line - pull Defcon/Subhire/ListType/MainSite->Slink1/Int1->Slink2(0 if NULL)/
--    DateOut->D1/DateBack->D2 from the destination Eqlists row; Category->Xcat/
--    Daily/Weight/Replacement from Hetype:
INSERT INTO "Sort"
  ("Type","Quant","Xcat","Eqlno","Virt","D1","D2","Alloc","Defcon","Subhire",
   "ListType","Daily","DailyMultiplier","PreDiscount","Discount","Price",
   "InvoicedTotal","Invoiced","Slink1","Slink2","sectionID","xFreeText",
   "SortOrder","RecType","xGUID","LoansInQty","SubHiredQty","CarnetQty",
   "PreppedQty","Out","Back","CheckedInQty","UnitWeight","UnitValue","NotBack",
   "xLateEqlno","xTransferInWarehouse")
VALUES (?, ?, ?, ?, FALSE, ?, ?, 0, ?, ?, ?, ?, 1, ?, ?, ?, 0, FALSE, ?, ?, ?, 0,
        ?, 1, NEWGUID, 0, 0, 0, 0, 0, 0, 0, ?, ?, FALSE, 0, 0);
```
Pricing formula (confirmed against a real client-created line):
`PreDiscount = Daily × Quant`, `Price = PreDiscount × (1 - Discount/100)`.
`RecType = 1` for a normal rental line. `SortOrder = MAX(SortOrder)+1` for
that Eqlist. **Still open / not yet verified:** whether job/eqlist header
totals (`Jobs.AllQuotedEquipment` etc.) recalculate correctly from a raw
insert or need a manual refresh, and behavior when the destination Eqlist
already has sections of its own (only tested against an empty Eqlist so far)
— re-verify carefully before relying on this for anything beyond a test job.

**3. `CopyEqlistLines`/`CreateNewEqlist` and friends** — the heavyweight
stored procedures HireTrack NX's own client uses. Still the *only* sanctioned
path if you need to replicate client-side business logic (markups, class
transfers, section copying) rather than a single new line — pattern #2 above
bypasses all of that, which is fine for a simple new line but not a
substitute for these procedures' full behavior.

**4. HireTrack's own `api_v2` REST API — found 2026-08-09, now the preferred
way to create/modify bookings over HTTP (supersedes pattern #2 for that use
case).** Not pyodbc at all — a REST API HireTrack NX itself exposes on the
same HTTP gateway/port already used for the `api_v1` QBE-lookup calls
elsewhere in this codebase (`hiretrack-eqlist-lookup.ts`,
`hiretrack-equipment-lookup.ts`, `hiretrack-repair-create.ts`) — same
`hiretrack.config.json` `baseUrl`/`headers`
(`target`/`ipaddress`/`port`/`alias`/`username`/`password`), just a
different URL prefix (`/api_v2/...` instead of `/api_v1/...`). Source: a
Navigator Systems Zendesk article the user found and downloaded
("HireTrack NX API V2"), cross-checked live against production.

Key actions (all take `hiretrack_user_id`/`hiretrack_client_id` plus
action-specific params — see the article for the full param list, or
`hiretrack-booking-api.ts` for the implementation):
- `check_availability` — real per-date-range availability, computed
  server-side by HireTrack's own booking engine. Returns
  `StocklevelForWarehouse` (total owned) and `AvailableQty` (free for the
  requested `[availability_datetime_from, availability_datetime_to]` range) —
  no need to reimplement `Sort.Defcon`/`Whlevel` logic yourself for this.
  Pure inquiry, no side effects (`WriteResult.WriteAction: 0` = `bwaInquiryOnly`).
- `initialise_new_booking` — creates a real Job + Eqlist. **Despite taking
  `hiretrack_type_id`/`quantity_required` params and being documented as
  creating "the first line" too, that embedded line never actually persists
  a `Sort` row on this server** — confirmed live by calling it alone (with
  ample stock) and reading `Sort` immediately after: zero rows. Treat its
  type/qty params as required-shape-only, not a real write; always follow
  with `append_to_booking` for every line, including what would have been
  the first. Returns `JobID`/`JobRef`/`EqlistID`/`EqRef`.
  **Also confirmed: `availability_datetime_from`/`availability_datetime_to`
  never reach the created Eqlist's actual `DateOut`/`DateBack` either.**
  Root cause found in `db.sql`'s `CreateNewEqlist` function (the real
  underlying stored function, which correctly accepts `aStartDate`/
  `aEndDate`): it clamps to `CURRENT_TIMESTAMP` whenever the passed date is
  earlier than "now" — `api_v2`'s `initialise_new_booking` action apparently
  never forwards the date params to it at all, so this clamp always fires,
  giving every new Eqlist `DateOut = now`, `DateBack = tomorrow 08:00`
  regardless of what was requested. Every subsequent `append_to_booking`
  call then fails with `ValidationResult: 6` (`bvrBookingDatesNEQListDates`)
  since the line's dates don't match the Eqlist's real (wrong) header dates.
  No `api_v2` action or stored procedure exists to change an Eqlist's dates
  after creation — the only fix is a direct
  `UPDATE Eqlists SET DateOut=?, DateBack=? WHERE Eql_no=?` via the writable
  DSN, immediately after `initialise_new_booking` and before any
  `append_to_booking` calls (`hiretrack_equipment_note_write.py`'s
  `update-eqlist-dates` operation). Only two plain date columns — no
  pricing/Sort/invoicing fields touched. Verified live end-to-end: both
  header dates and all `Sort.D1`/`D2` values match the requested range, and
  appends return `ValidationResult: 0`.
  **Further finding (2026-08-09, same investigation): the `CURRENT_TIMESTAMP`
  clamp value carries full microsecond precision, and `append_to_booking`
  rejects a date match against ANY stored `DateOut`/`DateBack` with a
  fractional second at all** — confirmed by sending the request with the
  exact same microsecond precision as the stored value (still rejected) and
  with the precision stripped from the request only (still rejected); only
  overwriting the *stored* value with a clean whole-second `UPDATE` fixed
  it. So a Job/Eqlist created before this whole fix was deployed stays
  permanently broken for appends until its stored dates are corrected —
  `hiretrack-job-lookup.ts`'s `lookupHiretrackJob` now detects this (the
  raw `.isoformat()`-serialized date contains `.`) and self-heals it via
  the same `update-eqlist-dates` path the first time the job is opened.
- `append_to_booking` — adds one more line to an existing Eqlist (needs the
  `EqlistID` from `initialise_new_booking`). Returns real pricing
  (`PreDiscountPrice`/`DiscountedPrice`/`DiscountRate`, pulled from the
  client's actual price list).
- `change_booking_quantity` — PUT, params `hiretrack_user_id`/
  `hiretrack_client_id`/`lineref_id`/`quantity_required`. Targets
  `Sort.Lineref` (the same id `append_to_booking` returns as `LineRefID`).
  Confirmed live (2026-08-09): changes the quantity and recalculates
  pricing correctly, `WriteAction: 6` (`bwaChangeQty`), `ValidationResult: 0`.
- `remove_from_booking` — PUT, params `hiretrack_user_id`/
  `hiretrack_client_id`/`lineref_id`/`jobref_id`. **`jobref_id` here is the
  numeric `JobID`/`Jobs.JobNo`, not the string `Job_Ref`** despite the
  name. Confirmed live: deletes the `Sort` row entirely (verified via a
  direct read afterward — 0 rows for that `Lineref`), `ValidationResult: 0`.
- `change_booking_line_discount`, `delete_job` — `delete_job` confirmed
  working (used repeatedly to clean up test bookings); `change_booking_line_discount`
  found in the doc, not yet exercised live.

**Confirmed live (2026-08-09):** `check_availability` against `Type 1203`
(healthy stock) returned `StocklevelForWarehouse: 141`, `AvailableQty: 130`
with correct RUB pricing; against `Type 660` (the equipment-catalog-match
feature's original bad-match case) returned `StocklevelForWarehouse: 0`,
`AvailableQty: 0`. `initialise_new_booking` + `append_to_booking` created
real Job 7182/Eqlist 10647 under the dedicated "Test client"
(`Company.CompanyCounter = 2` — use this for any experimentation, never a
real client), then `delete_job` cleanly removed it. Also confirmed
`append_to_booking` genuinely validates stock and refuses to write when
`AvailableQty` goes negative for the requested dates/qty (`ValidationResult:
7` = `bvrNoStockAvailable`, `BookingQty: 0`, no `Sort` row) — this is correct
behavior, not a bug; don't mistake a real stock shortfall for a write
failure.

**Non-obvious gotcha: the doc mislabels HTTP methods.** It labels
`check_availability` (and others) `GET` in the prose header, but its own
curl example for the same action uses `--request POST` — and live testing
confirmed **POST is correct**; `GET` returns `500 "No item found with name
check_availability"`. Trust the curl examples over the bolded method label
if they disagree.

**Useful default IDs found live (2026-08-09, production `SA` database):**
warehouse `1` = "Moscow" (`IsDefault=true`), pricelist `6` = "SA Rental
Scheme", user `1` = "HireTrack_Admin" (`SystemAdmin=true`), company `2` =
"Test client" (safe for `check_availability`/experimentation — never for a
real booking, which needs the actual client's `CompanyCounter`).

### Writing to HireTrack — personnel/crew (found, NOT yet executed — read-only research only, 2026-08-07)

The NX client is a thick client, and per-field `FIELD_DESC` text plus these
stored functions confirm crew records are **never created as a bare blank
`INSERT`** — the client always **clones an existing row** (a template
header/position, or the previous day when adding a shift), then date-shifts
it. All found in `db.sql`'s `CREATE FUNCTION`/`CREATE PROCEDURE` statements —
inspected as source only, never called.

- **`CloneCrewHeader(aHeaderID, aJobID, aDaysAdd, aCloneCrewDetails,
  aJobClone)`** (`db.sql:7884`) — creates a new `Crew_header` (phase) by
  cloning an existing one, offsetting `ScheduleStart/End`/`PriceStart/End` by
  `aDaysAdd` days (legacy crewing) or, for `NewCrewing=True` jobs, cloning the
  header's `CrewActivities` rows (the actual "Day N" calendar) and tracking
  the source via `xClonedFrom`. If `aCloneCrewDetails`, cascades into
  `CloneCrewEnhanced` (new crewing) or `CloneCrew` (legacy) to also clone the
  roles/positions/shifts underneath. Returns the new `Crew_header.Idx`.
- **`CloneCrewEnhanced(aCrewID, aJobID, aOldHeaderID, aNewHeaderID,
  aJobClone)`** (`db.sql:7764`) — the "New Crewing" (Enhanced) path: for each
  `Crew` role request under a header, clones the `Crew` row itself, then its
  `CrewPositions`, then that position's `CrewShifts` — but only for shifts
  whose `CrewActivities` row already has a matching `xClonedFrom` counterpart
  under the new header (shifts on days that don't exist in the new header get
  silently dropped). Ends by calling `TotalizeShiftsForRolesOnJob` to
  recalculate the parent `Crew` totals. **This is the function actually used
  when `NewCrewing=True`** (true for every job checked this session) —
  `CloneCrew` (legacy) explicitly refuses to run and tells the caller to use
  this one instead (`SIGNAL 'The CloneEnhancedCrew SP should be used instead
  of CloneCrew'`).
- **`CloneCrewPosition(aCrewPositionID, aCloneShifts)`** (`db.sql:7978`) — the
  simplest one: clones a single `CrewPositions` row (same `xCrewRequest`,
  same `Description` — i.e. this is exactly the mechanism behind a "Position
  #2" slot on the same role request) and optionally its `CrewShifts`. Returns
  the new `CrewPositions.IDX`.
- **`TotalizeShiftsForRolesOnJob(aJobID, aRoleIDs)`** (`db.sql:16060`) —
  recalculates `Crew.LabourCharge/PDCharge/TravelCharge/OvertimeCharge/
  AccommodationCharge(ForBilling)/LabourPay/.../Allocated/Selected` from that
  role's live `CrewShifts`. **Must be called after any shift-level mutation**
  affecting a role's totals — `CloneCrewEnhanced` already does this itself.
  `aRoleIDs` is a literal comma-separated ID list interpolated into dynamic
  SQL (`EXECUTE IMMEDIATE`), or blank for "the whole job."
- **`SyncCrewPositionOrderStatus(aPositionID)`** (`db.sql:15616`) and
  **`SyncCrewShiftOrderStatus(aShiftID, aSyncAfterOrdering)`** (`db.sql:15652`)
  — recompute a position's/shift's `OrderStatus` from its shifts'/purchase
  orders' state. **`SyncCrewPositionOffers(aSourcePosition,
  aDestPosition)`** (`db.sql:15587`) copies `CrewPositionOffers` rows from one
  position to another and pushes the source's `xPerson`/`Status` onto the
  destination (never downgrading `Status`) — this looks like the actual
  "assign this offered person to the position" commit step.
- Read-only helpers (`READS SQL DATA`, safe to `SELECT` directly, no `{CALL
  ...}` needed): `GetCrewFunctionNameFromCrewHeaderID(aCrewHeaderID)`,
  `GetCrewTitleFromCrewHeaderID(aCrewHeaderID)`,
  `GetCrewTypeTextFromID(aCrewTypeID)` (`db.sql:10899-10925`) — thin wrappers
  around the same joins already in the `personnel.crew_scheduling` section
  above; no need to call these separately if already joining `Crew_header`/
  `CREWTYPE` directly.

**Reframed (2026-08-07): this isn't a gap, it's the design.** No function
creates a brand-new `Crew_header`/`Crew`/`CrewPositions` chain from scratch —
every creation path goes through cloning something (a template header, the
previous day's shift, position #1 for a "Position #2"), then date-shifting.
Cloning an existing row *is* how this module creates records; there's no
separate "from scratch" primitive to go looking for. Practical takeaway for
Stage 3: adding a new role/position should itself clone the nearest existing
row (same header, or the same `xCrewRequest`) rather than trying to
`INSERT` a bare row with defaults — that's not just safer, it matches how the
NX client itself behaves, so downstream totals/sync procedures (see above)
get the same inputs they always do.

### NexusDB / pyodbc driver quirks (apply to any query against this DB)

- **`BYTE` columns return garbage large values unless cast.** `CAST(col AS
  SMALLINT)` (established first on `Item.CommissionStatus`/
  `BatchItemDisposals.Reason`, later hit again on `Hetype.Class`/
  `.Visibility` and `Sort.RecType`/`.ListType`). Assume any `BYTE` column
  needs this.
- **A data-modifying function cannot be called from a plain `SELECT` over
  ad-hoc ODBC.** `SELECT CreateNewNote(...) FROM #dummy` fails with
  `Functions that modify data may not be called in this context` — that form
  only works inside HireTrack's own QBE/procedural engine. Use the ODBC
  `{CALL func(?, ?, ...)}` escape instead, then fetch any return value via a
  separate `SELECT LASTAUTOINC FROM #dummy` — NexusDB also doesn't support
  the `{? = CALL ...}` output-parameter form (syntax error).
- **A Python `None` bound to a numeric column NexusDB can't coerce fails**
  with `Could not convert variant of type (OleStr) into type (Double)`. Pass
  the column's own documented `DEFAULT` value instead of `NULL`/`None`.
- **`GROUP BY`/`HAVING` reject an expression directly** (e.g. `GROUP BY
  CAST(x AS SMALLINT)` or `HAVING COUNT(*) > 3` both error). Wrap the
  expression in a derived subquery and group/filter on the outer alias
  instead: `SELECT x FROM (SELECT CAST(col AS SMALLINT) AS x FROM t) s GROUP
  BY x`.
- **Bare date-literal comparisons fail with a type mismatch** (`WHERE
  DateCol > '2026-01-01'` errors). Bind a real `datetime` as a parameter
  instead of an inline string literal.
- `NEWGUID` (no parentheses) works as a value expression directly inside an
  `INSERT ... VALUES (...)` list.
- `#dummy` is a built-in single-row pseudo-table (like Oracle's `DUAL`) —
  used throughout HireTrack's own procedures for `SELECT expr FROM #dummy`
  and works the same over plain ODBC.
- **`"#Fields"` and `"#Tables"` are live, queryable system tables** with the
  exact same columns as the `all.csv`/`fields from jobs.csv` exports (this is
  almost certainly how those CSVs were generated) — `SELECT * FROM "#Fields"
  WHERE TABLE_NAME = ?` gets you live `FIELD_DESC` for any table, including
  ones not covered by the existing CSV exports (e.g. `Name2`, most `Crew*`
  tables). `FIELD_DESC` frequently spells out the exact Pascal enum type and
  its member names for `BYTE`/`WORD` status-style columns — check here before
  reverse-engineering an enum from sample data. Must be double-quoted
  (`"#Fields"`) since NexusDB SQL treats `#` specially.
- **Reserved/ambiguous column names need double-quote identifiers, not square
  brackets.** `SELECT [Due Out] FROM JOBS` is a syntax error; `SELECT "Due
  Out" FROM JOBS` works. Hit this on `JOBS."Due Out"/"Due Back"`,
  `Crew."Out"/"Back"`, `Crew_header."Function"` — assume any short/common
  English word used as a column name needs quoting.
- **`UPPER()`/`LOWER()` don't fold Cyrillic case** — `UPPER('Job_Ref') =
  UPPER(?)` with a lowercase Cyrillic parameter silently matches nothing,
  even though the exact-case value matches fine (confirmed live on
  `Jobs.Job_Ref`). Works fine for Latin text (used successfully for
  case-insensitive `Company.CompanyName` search). For Cyrillic-heavy
  columns, prefer an exact/trimmed match, or `LIKE` with wildcards, over
  relying on case-folding.
- **Cyrillic `CHAR` columns decode correctly with plain `cp1251`** —
  `conn.setdecoding(pyodbc.SQL_CHAR, encoding="cp1251")` and same for
  `SQL_WCHAR`. If you see `�`/`?` garbage in Cyrillic text, it is very
  likely **not** a real decode failure — printing a cp1251-decoded Python
  string through an SSH pipe to a differently-configured console re-mangles
  it. Verify by writing results to a file with `io.open(path, "w",
  encoding="utf-8")` on the remote box and pulling the file via `scp`, never
  by reading printed console output over SSH.

### finance

- `Invoice.Client -> Company.CompanyCounter`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:2495)
- `Invoice.Job -> JOBS.JobNo`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:2498)
- `saleohead.Customernumber -> Company.CompanyCounter`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:4062)
- `purcohead.Customernumber -> Company.CompanyCounter`
  Source: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:3674)

## Important Soft Links

These fields exist and are useful, but are not protected by a foreign key in the exported DDL.

### jobs.general

- `JOBS.xMainVenue`
  Field exists in `JOBS`, but no FK to `venue.IDX` is present in `db.sql`
  Source field: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:5531)
- `JOBS.MainVenue`
  Plain text companion field
  Source field: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:3189)

### finance

- `saleihed.Compno`
  Column exists, but no FK to `Company.CompanyCounter` is declared in `db.sql`
  Table: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:4005)
- `purcihed.Compno`
  Column exists, but no FK to `Company.CompanyCounter` is declared in `db.sql`
  Table: [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:3617)
- `saleihed.Orderxref`
  Likely order link by business meaning, but not treated as a confirmed FK unless separately proven
- `purcihed.Orderxref`
  Likely purchase order link by business meaning, but not treated as a confirmed FK unless separately proven

## Financial Fields Used Right Now

Quoted totals currently sourced from `JOBS`:

- `AllQuotedEquipment`
- `AllQuotedCrew`
- `AllQuotedTransport`
- `AllQuotedMisc`

Source fields:

- [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:5484)
- [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:5485)
- [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:5486)
- [db.sql](/C:/Users/shpar/OneDrive/Документы/New%20project/Hiretrack/db.sql:5487)

Current integration rule:

- `totalQuotedAmount = AllQuotedEquipment + AllQuotedCrew + AllQuotedTransport + AllQuotedMisc`

## Query Rules

When writing SQL or QBE against HireTrack:

1. Start from `JOBS` for anything in `jobs.general`.
2. Use only confirmed FK paths where possible.
3. Treat `x...` fields without a DDL FK as soft links.
4. For `xMainVenue`, join only after checking real data consistency.
5. For `saleihed.Compno` and `purcihed.Compno`, join to `Company.CompanyCounter` only as a business assumption, not as a guaranteed FK.
6. If field description and DDL disagree, prefer the DDL.

## Recommended Join Paths

### jobs.general

```sql
JOBS
  -> Company      via JOBS.Client = Company.CompanyCounter
  -> Users        via JOBS.Handler = Users.UID
  -> Users        via JOBS.SalesPerson = Users.UID
  -> defcon       via JOBS.Status = defcon.Defcon_idx
  -> jobtypes     via JOBS.Type = jobtypes.Type_idx
  -> Projjob      via Projjob.xJob = JOBS.JobNo
  -> Project      via Projjob.xProject = Project.Idx
```

### personnel

```sql
JOBS
  -> defcon             via JOBS.Status = defcon.Defcon_idx      -- see Status Codes table above
  -> Crew_header         via Crew_header.XJob = JOBS.JobNo        -- Crew_header.Title = phase name shown in UI
  -> Crew                via Crew.Header = Crew_header.Idx        -- Crew.Type = role (join CREWTYPE for the name)
  -> CREWTYPE            via Crew.Type = CREWTYPE.Crewindex
  -> CrewPositions       via CrewPositions.xCrewRequest = Crew.Idx  -- xPerson IS NULL = unassigned
  -> Name2               via CrewPositions.xPerson = Name2.NameCounter
  -> CrewShifts          via CrewShifts.xPosition = CrewPositions.IDX
  -> CrewActivities      via CrewShifts.xActivity = CrewActivities.IDX  -- Description = "Day N"
```

### transport and equipment

```sql
JOBS
  -> EQLISTS            via EQLISTS.Job_no = JOBS.JobNo
```

### finance

```sql
JOBS
  -> Invoice            via Invoice.Job = JOBS.JobNo
Company
  -> saleohead          via saleohead.Customernumber = Company.CompanyCounter
Company
  -> purcohead          via purcohead.Customernumber = Company.CompanyCounter
```

## Known Caveats

- `JOBS.xCrewCoordinator` looks like a person field by description, but the real FK points to `Company.CompanyCounter`.
- `JOBS.xCrewManager` points to `Name2`, not `Users`.
- `JOBS.xMainVenue` exists, but no FK to `venue` is declared in this DDL export.
- invoice and order tables are partly constrained and partly only business-linked.
- `Hetype.xManufacturer`/`Hetype.MPN` are supplier/purchase-source fields, not
  brand/model — see "transport and equipment" above.
- A direct `Sort` insert only renders in the NX client if `sectionID` points
  at a real `EqSections` row — `NULL` inserts silently but invisibly. See
  "Writing to HireTrack" above.
- `CrewTasks.Status` and `Name2.xRecordStatus` are both documented as
  `TRecordStatus` in `FIELD_DESC`, but they are **different enums with
  different members** (`CrewTasks.Status`: rsAny/ctsLegacy/ctsNew/ctsRetired
  vs `Name2.xRecordStatus`: rsIntended/rsPending/rsAccepted/rsDeleted) — the
  Delphi type name was reused, don't map one table's codes using the other's
  member list just because the type name matches.
- `defcon.Defcon_text` is not unique — codes `-3` and `5` both display
  "Завершено" but are distinct rows with different `SortOrder`.

## Use This File For

- writing new QBE SQL
- checking whether a join is confirmed or inferred
- deciding where a new field belongs in the domain model
- avoiding false assumptions from field names alone
