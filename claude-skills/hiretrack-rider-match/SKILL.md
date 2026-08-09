---
name: hiretrack-rider-match
description: >
  Matches a touring collective's technical rider (any format — PDF, DOCX, XLSX, or pasted text,
  wildly inconsistent structure) against the user's own live HireTrack NX equipment inventory,
  and can write the confirmed matches into HireTrack as a Note.
  Use this skill when the user uploads or pastes a technical rider and wants to know which items
  in their own HireTrack stock correspond to it, or wants those matched items added to HireTrack.
  Trigger on: "загрузи райдер", "подбери оборудование по райдеру", "сопоставь с HireTrack",
  "что у нас есть под этот райдер", "создай note в hiretrack", "match rider to inventory",
  "check our stock against this rider", or any upload of a technical rider/tech spec from a
  band or touring collective when the user wants it matched against their own equipment, not a
  vendor catalog (for vendor quotations/BOMs use the av-quotation skill instead).
---

# HireTrack Rider Match

You help match a touring collective's technical rider against the user's own **HireTrack NX**
equipment inventory (not a vendor catalog — this is their own stock), checking real per-date
availability along the way. The equipment catalog is read live from HireTrack's production
database through a small service already running there; matched items can optionally be written
into HireTrack as a **Note** or a **real booking** (see Hard rules).

Full design background, schema decisions, and the reasoning behind the write path live in
`EQUIPMENT_CATALOG_MATCH_BLUEPRINT.md` in the HireTrack project
(`New project/Hiretrack/EQUIPMENT_CATALOG_MATCH_BLUEPRINT.md`) — read it if anything here is
unclear or if the backend contract seems to have changed.

## Availability-aware matching (2026-08-09)

Matching is **date-aware**: `scripts/check-availability.sh` calls HireTrack's own `api_v2`
booking engine (`check_availability`), which computes real per-date-range availability
server-side — `StocklevelForWarehouse` (total owned) and `AvailableQty` (free for the requested
dates, accounting for overlapping bookings). This replaced an earlier text-only matcher that once
picked a 0-stock "Professional Music Stand" over a near-identical ~206-unit alternative purely on
text similarity — call this per shortlisted candidate (see Step 5) and use the real numbers, don't
guess from stock text or skip the check for candidates that "look" common.

## Hard rules

- **Never treat `xManufacturer`/`MPN` fields as brand/model.** In this HireTrack setup those
  record the supplier/purchase source, not the equipment's actual brand or model. The catalog
  endpoint doesn't even return them — brand/model live in the item's `name` (HireTrack
  `Hetype.Description`) as free text.
- **Never write to HireTrack without showing the user the exact proposed lines first and getting
  an explicit go-ahead.** Both write paths below create real data in production HireTrack.
- **Two write paths, different weight — pick deliberately, don't default to the bigger one:**
  - `scripts/create-note.sh` — writes a **Note** (`Notebook`/`notebookdetails`) only. Lightweight,
    no Job/Eqlist created, safe default when the user just wants a written record of the match.
  - `scripts/create-booking.sh` — creates a **real Job + Eqlist** via HireTrack's own `api_v2`
    (`initialise_new_booking` + `append_to_booking` per line, confirmed live 2026-08-09: correct
    pricing/discount from the client's price list, and a matching `delete_job` call cleanly
    reverses it if needed). Use this only when the user explicitly wants an actual booking created,
    not just a record — it needs a **real HireTrack client id** (`hiretrack_client_id` /
    `Company.CompanyCounter`), which the skill must ask the user for rather than guess. Never point
    this at a real client without the user confirming the dates/client are correct first — unlike a
    Note, this is a live booking that shows up in the client's own job history.

## Configuration (ask the user once, then reuse)

These come from the user, not from guessing:

- `HIRETRACK_BASE_URL` — where the HireTrack service is reachable, default `http://localhost:3001`
  (only correct once a tunnel is up — see below)
- `HIRETRACK_ACCESS_PASSWORD` — the stock-check portal password
- SSH tunnel target (`<user>@<host>`) if the service isn't already reachable directly — the user
  confirmed access is via SSH tunnel for now, using the `hiretrack_stocktakes_ed25519` key

If any of these are unset when needed, ask the user rather than guessing at a host/port/password.

## Workflow

### Step 1 — Ensure connectivity

Check whether `$HIRETRACK_BASE_URL` (default `http://localhost:3001`) is already reachable
(`curl -sS -f -o /dev/null "$HIRETRACK_BASE_URL/health"`). If not, and the user has given an SSH
target, start the tunnel in the background and wait for it to come up:

```bash
ssh -i ~/.ssh/hiretrack_stocktakes_ed25519 -N -L 3001:localhost:3001 <user>@<host>
```

### Step 2 — Fetch/cache the catalog

Run `scripts/fetch-catalog.sh` and cache the JSON response to
`~/.claude/skills/hiretrack-rider-match/cache/equipment-catalog.json` with a fetch timestamp.
Re-fetch only if the cache is older than ~15 minutes — the server already does the expensive
sync work (full query once, cheap deltas after), this cache is just to avoid redundant round
trips over the tunnel within one session.

### Step 3 — Parse the rider

Read the uploaded file. Delegate format handling to the existing `pdf`, `docx`, or `xlsx` skills
as needed — don't reimplement file parsing here. Extract a flat list of line items: free-text
description + quantity (default 1 if not stated). Don't try to pre-classify category/brand
yourself yet — keep the raw text, matching happens next.

Also extract the **event/show date range** if the rider states one (load-in/load-out, show dates,
"Due Out"/"Due Back" wording). This drives the availability check in Step 5. If the rider doesn't
state dates, ask the user for a date range before continuing — don't invent one or skip the
availability check silently. Format as `"YYYY-MM-DD HH:MM:SS"` for the scripts below.

### Step 4 — Shortlist candidates

Write the rider lines to a temp JSON file (`[{ "text": "..." }, ...]`) and run:

```bash
node scripts/prefilter-candidates.js <catalog.json> <rider-lines.json> 8
```

This narrows the 7000+ item catalog down to ≤8 candidates per rider line using token overlap —
it is a cheap pre-filter only, not the final answer.

### Step 5 — Match with judgment

Each candidate the pre-filter returns carries `similarGroup`, `equipmentType`, and `accessories`
(mandatory/optional) alongside the raw name — use them, don't just eyeball item names:

1. **Check `similarGroup` first.** `Similars` is a curated functional taxonomy (~48 groups —
   "Микрофон вокальный", "Дибокс", "Тарелка крэш", "Рэк том", "Стойка для хай-хета", etc.) that's
   a much cleaner match target than raw SKU text. If several candidates share a group that matches
   the rider line's intent, that's a strong signal you're in the right neighborhood — pick among
   that group by any brand/model hint the rider gives, or note that any member is acceptable if it
   doesn't specify.
2. **Check `equipmentType`.** `0` = plain item (etSimple). `1` = Composite Kit — a single bookable
   type that already bundles components (e.g. a hi-hat top+bottom pair as one type). `2`/`3` =
   Alias / Priced Alias Kit — a pre-bundled system/package (e.g. a wireless system with receiver +
   handhelds, or a console + stage-box package). When a rider line describes a "pair", "system", or
   "package" rather than one discrete part, prefer an existing Composite/Alias type over manually
   assembling the pieces yourself — it's already modeled that way in HireTrack for a reason. Each
   candidate carries its actual `components` (the real recipe, from HireTrack's own `COMPOSIT`
   table — confirmed live, not guessed) when `equipmentType > 0`, so you can verify the bundle
   actually matches the rider line's intent before picking it, rather than assuming from the name.
3. **Check `accessories`.** If the matched type carries accessories with `required: true`, treat
   those as part of the match — add them too, don't leave a mandatory accessory out. Accessories
   with `required: false` are worth surfacing to the user as optional add-ons, not auto-included.
4. Only fall back to plain text/model-number reasoning (brand, abbreviations, category context)
   when `similarGroup` doesn't help or is absent for that item.
5. **Keep brand consistent within a family of related lines**, not just per-line. If the rider
   picks a shell brand for the drum kit (e.g. "Yamaha Maple Custom"), match *every* drum shell/head
   *and generic hardware* (cymbal stands, hi-hat stand, snare stand) to that same brand where the
   catalog has it — don't let one line default to a different brand just because it scored well in
   isolation. Same for cymbals: if one cymbal is matched to a brand, match the rest of the cymbal
   set to that brand too, even across separate rider lines (hi-hat/crash/ride/splash). The
   exception: when the rider names a **specific model** for one part (e.g. "TAMA Iron Cobra 900"
   pedal, "TAMA Round Rider XL Trio" throne) independent of the shell brand, honor that exact
   request rather than forcing it to match the shell brand.
6. **Check real availability for the rider's dates** on your top 1-2 candidates per line once
   you've narrowed to a likely match — not on every raw shortlist item, that's wasted calls:
   ```bash
   scripts/check-availability.sh <typeId> <quantity> "<dateFrom>" "<dateTo>"
   ```
   Returns `stocklevelForWarehouse` (total owned) and `availableQty` (actually free for those
   dates). If `availableQty` is 0 or below the requested quantity, don't pick that candidate
   silently — either fall back to a generic alternative that covers the qty, or flag the shortfall
   to the user explicitly (e.g. "only 3 of 5 requested are free that week"). A perfect text/brand
   match with insufficient availability is not a good match.

Assign a confidence per line:

- **High** — clear model/brand match, or unambiguous within a matched Similars group
- **Medium** — plausible category+partial-text match, worth a second look
- **Low / no match** — nothing in the shortlist is convincing; flag for manual review rather than
  guessing

If a rider line clearly isn't equipment (headers, section titles, notes) skip it.

### Step 6 — Present results

Show a table: rider line → matched HireTrack item (`typeId` + name + category) → availability for
the rider's dates (`availableQty` / requested qty) → confidence, with unmatched/low-confidence and
insufficient-availability items clearly separated at the bottom. This table is also the
write-confirmation prompt — end by asking whether to write the confirmed items, and **which of the
two write paths** the user wants (see Hard rules): a Note (record only) or a real booking (creates
a Job + Eqlist — ask for the HireTrack client id if they choose this).

### Step 7 — Write (only after explicit confirmation)

**Option A — Note** (default, lighter-weight):

```json
{
  "title": "Rider - <collective/job name>",
  "clientName": "<optional>",
  "lines": [
    { "eqtype": 1234, "qty": 2 },
    { "eqtype": 5678, "qty": 1 }
  ]
}
```

```bash
scripts/create-note.sh /path/to/payload.json
```

Report back the created `noteId` and how many lines were written (the response includes
`failedLines` for any line that didn't insert — surface those explicitly, don't silently drop
them).

**Option B — real booking** (only if the user explicitly asked for an actual booking, and gave you
a real `clientId`):

```json
{
  "jobName": "Rider - <collective/job name>",
  "clientId": 123,
  "dateFrom": "<dateFrom from Step 3>",
  "dateTo": "<dateTo from Step 3>",
  "lines": [
    { "typeId": 1234, "quantity": 2 },
    { "typeId": 5678, "quantity": 1 }
  ]
}
```

```bash
scripts/create-booking.sh /path/to/payload.json
```

Report back `jobId`/`jobRef`/`eqlistId`/`eqRef` and how many lines were written (`failedLines`
same as above). Tell the user the job ref so they can open it directly in HireTrack NX.
