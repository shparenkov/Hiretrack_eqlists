#!/usr/bin/env bash
# Logs into the HireTrackStocktakes service and creates an equipment Note
# (Notebook/notebookdetails) from a confirmed match list. NEVER call this
# without having already shown the proposed title + line list to the user and
# gotten an explicit go-ahead - this writes real data into production
# HireTrack. See EQUIPMENT_CATALOG_MATCH_BLUEPRINT.md for why this targets a
# Note and not a live Job Eqlist.
#
# Usage: create-note.sh <payload.json>
# payload.json shape:
#   {
#     "title": "Rider - Band Name",
#     "clientName": "optional",
#     "lines": [ { "eqtype": 1234, "qty": 2 }, ... ]
#   }
set -euo pipefail

BASE_URL="${HIRETRACK_BASE_URL:-http://localhost:3001}"
: "${HIRETRACK_ACCESS_PASSWORD:?Set HIRETRACK_ACCESS_PASSWORD (the stock-check portal password)}"

PAYLOAD_FILE="${1:?Usage: create-note.sh <payload.json>}"
if [ ! -f "$PAYLOAD_FILE" ]; then
  echo "Payload file not found: $PAYLOAD_FILE" >&2
  exit 1
fi

COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

curl -sS -f -c "$COOKIE_JAR" -X POST "$BASE_URL/login" \
  --data-urlencode "password=$HIRETRACK_ACCESS_PASSWORD" \
  -o /dev/null

curl -sS -f -b "$COOKIE_JAR" -X POST "$BASE_URL/api/tickets/lookups/equipment-notes" \
  -H "Content-Type: application/json" \
  --data-binary "@$PAYLOAD_FILE"
