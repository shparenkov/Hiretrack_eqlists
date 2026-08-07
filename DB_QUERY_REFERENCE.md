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
- `personnel`
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
  -> Crew               via Crew.Job_no = JOBS.JobNo            -- business link, not FK in DDL slice above
  -> CrewPositions      via CrewPositions.xCrewRequest = Crew.Idx
  -> CrewShifts         via CrewShifts.xPosition = CrewPositions.IDX
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

## Use This File For

- writing new QBE SQL
- checking whether a join is confirmed or inferred
- deciding where a new field belongs in the domain model
- avoiding false assumptions from field names alone
