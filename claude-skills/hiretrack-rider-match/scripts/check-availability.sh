#!/usr/bin/env bash
# Logs into the HireTrackStocktakes service and checks real date-range
# availability for one equipment type via HireTrack's own api_v2 booking
# engine (StocklevelForWarehouse / AvailableQty computed server-side - not a
# guess from static stock counts). Call this per shortlisted candidate during
# matching, not for the whole catalog.
#
# Usage: check-availability.sh <typeId> <quantity> <dateFrom> <dateTo>
#   dateFrom/dateTo format: "YYYY-MM-DD HH:MM:SS" (quote it as one argument)
set -euo pipefail

BASE_URL="${HIRETRACK_BASE_URL:-http://localhost:3001}"
: "${HIRETRACK_ACCESS_PASSWORD:?Set HIRETRACK_ACCESS_PASSWORD (the stock-check portal password)}"

TYPE_ID="${1:?Usage: check-availability.sh <typeId> <quantity> <dateFrom> <dateTo>}"
QUANTITY="${2:?Usage: check-availability.sh <typeId> <quantity> <dateFrom> <dateTo>}"
DATE_FROM="${3:?Usage: check-availability.sh <typeId> <quantity> <dateFrom> <dateTo>}"
DATE_TO="${4:?Usage: check-availability.sh <typeId> <quantity> <dateFrom> <dateTo>}"

COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

curl -sS -f -c "$COOKIE_JAR" -X POST "$BASE_URL/login" \
  --data-urlencode "password=$HIRETRACK_ACCESS_PASSWORD" \
  -o /dev/null

curl -sS -f -b "$COOKIE_JAR" -G "$BASE_URL/api/tickets/lookups/equipment-availability" \
  --data-urlencode "typeId=$TYPE_ID" \
  --data-urlencode "quantity=$QUANTITY" \
  --data-urlencode "dateFrom=$DATE_FROM" \
  --data-urlencode "dateTo=$DATE_TO"
