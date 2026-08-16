# Hiretrack_eqlists

Cross-project HireTrack NX reference material and the `hiretrack-rider-match`
Claude Skill, mirrored here for off-machine backup/collaboration.

This is a **curated export**, not the primary working copy of any app:

- `DB_QUERY_REFERENCE.md` — general HireTrack NX / NexusDB schema and pyodbc
  driver-quirk reference (equipment catalog relationships, confirmed write
  patterns, ODBC gotchas). Reused by any HireTrack integration, not tied to
  one feature.
- `EQUIPMENT_CATALOG_MATCH_BLUEPRINT.md` — design doc for the rider-matching
  feature built into `stocktakes-app` (separate repo:
  `github.com/shparenkov/hiretrack_stocktakes`).
- `SCANNER_APP_BLUEPRINT.md` — API research and architecture for a planned
  commercial mobile scanner add-on (separate product, no code yet), built on
  HireTrack NX's Remote Operation Note control API rather than the
  booking-write API the other two docs cover.
- `claude-skills/hiretrack-rider-match/` — backup of the live Claude Skill.
  The copy Claude Code actually loads at runtime lives at
  `~/.claude/skills/hiretrack-rider-match/` on whichever machine runs a
  session; that location isn't version-controlled, so this is a mirror kept
  here for safety. The two don't auto-sync — copy changes by hand in either
  direction.
- `db.sql` / `all.csv` — HireTrack NX schema reference the docs above link
  against.

Some internal links in the two `.md` files still use absolute local paths
from the original workspace (`C:/Users/shpar/OneDrive/.../Hiretrack/...`) and
may not resolve on GitHub — the surrounding text is still accurate, just
follow the filenames rather than the links until those get cleaned up.

The actual application code (`stocktakes-app`) lives in its own repo. This
repo intentionally excludes the broader "New project" workspace it was
extracted from (unrelated AV-emulator work, etc.).
