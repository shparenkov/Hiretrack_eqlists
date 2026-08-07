# Claude Skills backup

This folder is a **backup/mirror**, not the live copy. The actual skill
Claude Code loads at runtime lives at `~/.claude/skills/<name>/` on whichever
machine is running a session — that location isn't version-controlled on its
own, so a copy is kept here under git for safety and for reference by other
tools/sessions working on this project (Codex included).

If you change a skill here, also copy the change to `~/.claude/skills/<name>/`
(or vice versa) — they don't sync automatically.

## `hiretrack-rider-match`

Matches a touring collective's technical rider against HireTrack NX's own
equipment inventory and can write matches into HireTrack as a Note. See
`hiretrack-rider-match/SKILL.md` and
[EQUIPMENT_CATALOG_MATCH_BLUEPRINT.md](../EQUIPMENT_CATALOG_MATCH_BLUEPRINT.md)
for the full design.
