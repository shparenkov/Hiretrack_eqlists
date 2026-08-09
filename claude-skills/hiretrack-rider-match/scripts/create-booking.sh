#!/usr/bin/env bash
# Logs into the HireTrackStocktakes service and creates a REAL Job + Eqlist
# booking via HireTrack's own api_v2 (initialise_new_booking + one
# append_to_booking per additional line) - not a Note. NEVER call this
# without having already shown the proposed job name/client/dates/line list
# to the user and gotten an explicit go-ahead: this creates a real booking in
# production HireTrack, a bigger action than create-note.sh's Note write.
#
# Usage: create-booking.sh <payload.json>
# payload.json shape:
#   {
#     "jobName": "Rider - Band Name",
#     "clientId": 123,
#     "dateFrom": "2026-09-01 00:00:00",
#     "dateTo": "2026-09-05 00:00:00",
#     "lines": [ { "typeId": 1234, "quantity": 2 }, ... ]
#   }
set -euo pipefail

BASE_URL="${HIRETRACK_BASE_URL:-http://localhost:3001}"
: "${HIRETRACK_ACCESS_PASSWORD:?Set HIRETRACK_ACCESS_PASSWORD (the stock-check portal password)}"

PAYLOAD_FILE="${1:?Usage: create-booking.sh <payload.json>}"
if [ ! -f "$PAYLOAD_FILE" ]; then
  echo "Payload file not found: $PAYLOAD_FILE" >&2
  exit 1
fi

COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

curl -sS -f -c "$COOKIE_JAR" -X POST "$BASE_URL/login" \
  --data-urlencode "password=$HIRETRACK_ACCESS_PASSWORD" \
  -o /dev/null

curl -sS -f -b "$COOKIE_JAR" -X POST "$BASE_URL/api/tickets/lookups/equipment-bookings" \
  -H "Content-Type: application/json" \
  --data-binary "@$PAYLOAD_FILE"
