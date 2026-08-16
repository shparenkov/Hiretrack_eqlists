# Mobile Scanner App — Blueprint

Design doc for a **commercial mobile add-on** to HireTrack NX: a phone app
with a built-in camera scanner for warehouse dispatch (goods-out) work,
sellable to any HireTrack NX customer, not tied to one company's server.
Separate from `EQUIPMENT_CATALOG_MATCH_BLUEPRINT.md` (rider-matching, uses a
different HireTrack surface — see "Two unrelated `api_v2` APIs" below) and
from `stocktakes-app`'s own planned "barcode scanner UI" item (that one reads
stock levels via the read-only pyodbc DSN; this app is a separate product).

No code exists yet. This doc captures the API research needed before picking
a stack/repo.

## Two unrelated `api_v2` APIs — don't conflate them

Navigator Systems ships two separate things both branded "HireTrack NX API
V2", reachable at different ports with different auth models. Prior work in
this repo (`DB_QUERY_REFERENCE.md`, `EQUIPMENT_CATALOG_MATCH_BLUEPRINT.md`)
only documents the first one:

1. **Booking-write REST API** (already used in `hiretrack_stocktakes` /
   `hiretrack-booking-api.ts`) — `check_availability`,
   `initialise_new_booking`, `append_to_booking`, `change_booking_quantity`,
   `remove_from_booking`, `delete_job`, etc. Pure server-side HTTP against
   the same gateway/port used for `api_v1` QBE lookups
   (`hiretrack.config.json` `baseUrl`/`ipaddress`/`port`/`alias`). No live
   desktop client needed. Operates on **Jobs/Eqlists** (bookings).

2. **Remote Operation Note control API** (this doc, new — from the five
   Zendesk articles the user supplied 2026-08-16) — `GUI_set_opsnote`,
   `GUI_barcode`, `GUI_get_property`/`GUI_set_property`,
   `GUI_get_grid`/`GUI_get_grid_delta`. Requires a **live, paired HireTrack
   NX desktop client** talking to the local **HireTrack NX Integration
   Service** on port `10055`. Operates on **Operation Notes**
   (`operationsheader.idx`) — HireTrack's warehouse dispatch/goods-out(-in)
   documents, not Jobs/Eqlists directly.

**This is the one that matters for the scanner app.** It's purpose-built for
exactly this use case (mobile field scanning against a warehouse document)
and every business rule (stock checks, "not booked, add it?" prompts,
pricing) is enforced by HireTrack's own client logic — nothing to
reimplement.

## Architecture reality: this is not a stateless cloud API

The Operation Note control API is bound to one running desktop session, not
a customer's server in the abstract:

- A HireTrack NX **desktop client must be open and paired**. Pairing happens
  via a **QR code** shown by the "Pair Mobile" button (inside an open
  Operation Note, or on the "My HireTrack" screen). That button only appears
  if the client was launched with `/MOBILE`, or the `PairMobile`
  `UserSettings` flag is set org-wide (SQL snippet in the source doc).
- The QR payload gives the mobile app everything needed for a session:
  `hiretrack_session_id` (GUID, **tied to that specific running client
  instance** — invalidated on client restart, requires re-pairing),
  `hiretrack_user_id` (GUID API key, stable across password changes), and
  the DB connection headers (`ipaddress`/`port`/`alias`, same shape as the
  `api_v1`/booking-write config).
- All calls go to `{protocol}://{integration_service_host}:10055/api_v2/...`
  — `integration_service_host` is the **warehouse PC running the desktop
  client**, not a cloud endpoint. The phone needs network reachability to
  that PC (same LAN/Wi-Fi by default; VPN or reverse proxy if remote scanning
  is wanted — a per-customer deployment concern, not a code one).
- Prerequisites: HireTrack NX Integration Service `2.0.0.41+`, client
  `271.24+`.
- **Product/sales implication**: onboarding a new customer isn't just "give
  them an app" — their IT needs the Integration Service running, the
  PairMobile flag on, and the warehouse PC's port `10055` reachable from
  scanner phones. Worth a one-page onboarding checklist before this ships
  commercially.

## Endpoint reference

All four endpoints share headers `target: api_key`, `ipaddress`, `port`,
`alias` (DB connection, same as `api_v1`/booking-write), `Content-Type:
application/json`, and query params `hiretrack_record_id` (the Operation
Note's `operationsheader.idx`), `hiretrack_session_id`, `hiretrack_user_id`,
`hiretrack_timeout` (default 5000ms).

### `POST /api_v2/GUI_set_opsnote`

Opens an Operation Note in the paired client, or focuses it if already open.
No body. Success: `[{"Note Open":"81912"}]`. Failure (e.g. bad record id):
`{"ErrorClass":"ERecordNotFound","ErrorMessage":"...","ErrorCallStack":""}`.

**Open question**: nothing in these docs covers *listing* Operation Notes to
let the user pick one — the app needs a `hiretrack_record_id` from
somewhere. Likely the existing `api_v1` QBE pattern already used for
Job/Eqlist lookups (`hiretrack-eqlist-lookup.ts` etc.) covers Operation
Notes too, but that needs confirming against the QBE catalog rather than
assumed.

### `POST /api_v2/GUI_barcode` — the scan loop, this is the core UX

Request: same headers, plus query param `hiretrack_barcode`. Response is one
of:

- **Clean scan**: `[{"009051":"Scan OK"}]` (key = the barcode).
- **Issue(s)**, array of objects:
  ```json
  {
    "Barcode": "093670",
    "ScanIssue": 1,
    "ScanIssueEnumStr": "siBarcodeNotFound",
    "IssueString": "Barcode 093670 not found",
    "UserResponseRequired": false,
    "UserResponseDataType": 0,
    "UserResponseDataTypeEnumStr": "rdtNull",
    "UserResponse": null
  }
  ```
  `UserResponseDataType` (0 `rdtNull`, 1 `rdtBoolean`, 2
  `rdtBooleanAsInteger`, 3 `rdtInteger`, 4 `rdtDecimal`, 5 `rdtString`)
  drives which input widget the app renders when `UserResponseRequired` is
  true — e.g. `siTypeNotRequiredAddPrompt`: *"Type X is not booked on this
  list. Would you like to add it?"* (boolean). App fills in `UserResponse`
  on the **same object** and POSTs the **whole array** back to the identical
  URL to continue; may loop (a resolved issue can surface a new one) until a
  final `"Scan OK"` or an issue with `UserResponseRequired: false` (terminal,
  informational only).

This interactive protocol is the whole point of building the scanner into
the app rather than bolting on a generic barcode reader: every scan is a
round-trip through HireTrack's real validation, with the same prompts a
warehouse operator would see on the desktop client.

### `POST /api_v2/GUI_get_grid` and `GUI_get_grid_delta`

Read-only view of the Operation Note's grid (line items, quantities,
statuses) — this is what lets the app show live scan progress **without any
separate DB read path**. `GUI_get_grid` returns the full
columns+cells+formatting; `GUI_get_grid_delta` returns only rows that
changed since the last full/delta fetch, plus viewport info
(`topRowIndex`/`visibleRowCount`/`viewportChanged`). Use full fetch once
after opening the note, then poll delta after each scan (or on an interval)
to refresh a "picked X of Y" screen. Note: formatting is only guaranteed
correct for rows currently on-screen in the desktop client (`offScreen`
flag) — don't rely on off-screen cell formatting, only `value`/`displayText`.

### `POST /api_v2/GUI_get_property` and `GUI_set_property`

Generic read/write of named component properties on the active form (e.g.
`CurrentCaseComboBox.Text`, `ToDoAndDoneTabSet.ActiveTabIndex`,
`AutoIncChkBox.Checked`). Component names aren't discoverable via the API —
only the handful listed in the doc are documented; anything else needs
asking Navigator support. Likely a secondary tool for MVP (e.g. toggling
"auto-increment" scan mode or switching the outstanding/done tab), not a
day-one dependency.

## Proposed MVP flow

1. **Pair**: user scans the HireTrack "Pair Mobile" QR from the warehouse
   PC → app stores `session_id`, `user_id`, `ipaddress`/`port`/`alias` for
   that site. Re-pair when the desktop client restarts (session_id dies).
2. **Open note**: user picks/enters an Operation Note → `GUI_set_opsnote`.
3. **Scan loop**: camera decodes a barcode → `GUI_barcode` → render "Scan
   OK" toast, or render the issue prompt(s) and collect responses →
   resubmit → repeat.
4. **Live progress**: `GUI_get_grid` once after opening, then
   `GUI_get_grid_delta` after each scan/on an interval, rendered as a
   picked-vs-required list.

Return/goods-in scanning, multi-site management, and the
`GUI_get_property`/`set_property` surface are follow-ups, not MVP.

## Open questions before build starts

- How does the app enumerate/select Operation Notes to open (no list
  endpoint documented here — check the existing `api_v1` QBE catalog)?
- The Barcode API doc references a **"General Returns API"** for the
  goods-in side — not among the five docs supplied; needed once returns
  scanning is in scope.
- `10055` is plain HTTP by default ("HTTP ... only available when running
  Integration Service in GUI mode") with HTTPS also listed as supported —
  need to confirm whether customer sites will actually run it with a cert,
  since both Android and iOS restrict cleartext HTTP from native apps by
  default and that restriction would need an explicit, scoped exception per
  customer host rather than a blanket bypass.
- Per-site reachability story (LAN-only vs VPN vs reverse proxy) needs a
  decision before this is sellable beyond a single warehouse's Wi-Fi.
