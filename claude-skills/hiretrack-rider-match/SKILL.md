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
equipment inventory (not a vendor catalog — this is their own stock). The equipment catalog is
read live from HireTrack's production database through a small service already running there;
matched items can optionally be written into HireTrack as a **Note**.

Full design background, schema decisions, and the reasoning behind the write path live in
`EQUIPMENT_CATALOG_MATCH_BLUEPRINT.md` in the HireTrack project
(`New project/Hiretrack/EQUIPMENT_CATALOG_MATCH_BLUEPRINT.md`) — read it if anything here is
unclear or if the backend contract seems to have changed.

## Known limitation (not yet fixed)

Matching currently only looks at the `Hetype` catalog text — it has **no visibility into physical
stock or availability**. A candidate can be a perfect text match while having 0 physical units in
`Item` (confirmed live: "Professional Music Stand" matched and got written to an eqlist despite 0
stock, while a near-identical generic stand had ~206). Until date-aware availability is built (see
"Planned" section in the blueprint doc), flag this explicitly to the user for any candidate you
suspect might be low-stock/niche, and prefer a more generic/common alternative when one exists and
fits the rider line just as well — don't rely on text-match score alone.

## Hard rules

- **Never treat `xManufacturer`/`MPN` fields as brand/model.** In this HireTrack setup those
  record the supplier/purchase source, not the equipment's actual brand or model. The catalog
  endpoint doesn't even return them — brand/model live in the item's `name` (HireTrack
  `Hetype.Description`) as free text.
- **Never write to HireTrack without showing the user the exact proposed lines first and getting
  an explicit go-ahead.** The write step creates a real Note in production HireTrack.
- **This skill's built-in write path (`scripts/create-note.sh`) only writes to a Note
  (`Notebook`/`notebookdetails`).** Direct writes to a live Job's equipment list
  (`EQLISTS`/`Sort`) have been proven to work (confirmed live, on a job created specifically for
  testing — see "Live Eqlist (Sort) writes" in the blueprint doc for the working field template),
  but that path isn't wrapped into this skill's scripts yet — it was done via ad-hoc Python against
  the writable `Claude` DSN. If the user asks for a real Job's Eqlist to be written to directly,
  don't attempt it ad hoc against a real booking without the same caution used when this was
  tested — confirm it's safe to write to (not a real show), and read the blueprint's open questions
  (totals recalculation, existing-sections case) first.

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

Assign a confidence per line:

- **High** — clear model/brand match, or unambiguous within a matched Similars group
- **Medium** — plausible category+partial-text match, worth a second look
- **Low / no match** — nothing in the shortlist is convincing; flag for manual review rather than
  guessing

If a rider line clearly isn't equipment (headers, section titles, notes) skip it.

### Step 6 — Present results

Show a table: rider line → matched HireTrack item (`typeId` + name + category) → confidence,
with unmatched/low-confidence items clearly separated at the bottom. This table is also the
write-confirmation prompt — end by asking whether to create a HireTrack Note from the confirmed
items.

### Step 7 — Write (only after explicit confirmation)

Build a payload file:

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

Only include lines the user confirmed. Then:

```bash
scripts/create-note.sh /path/to/payload.json
```

Report back the created `noteId` and how many lines were written (the response includes
`failedLines` for any line that didn't insert — surface those explicitly, don't silently drop
them).
