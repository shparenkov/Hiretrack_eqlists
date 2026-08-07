#!/usr/bin/env bash
# Logs into the HireTrackStocktakes service and prints the equipment catalog
# JSON to stdout. Assumes the service is already reachable at $HIRETRACK_BASE_URL
# (default http://localhost:3001) - e.g. via an SSH tunnel started separately:
#   ssh -i ~/.ssh/hiretrack_stocktakes_ed25519 -N -L 3001:localhost:3001 <user>@<host>
set -euo pipefail

BASE_URL="${HIRETRACK_BASE_URL:-http://localhost:3001}"
: "${HIRETRACK_ACCESS_PASSWORD:?Set HIRETRACK_ACCESS_PASSWORD (the stock-check portal password)}"

COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

curl -sS -f -c "$COOKIE_JAR" -X POST "$BASE_URL/login" \
  --data-urlencode "password=$HIRETRACK_ACCESS_PASSWORD" \
  -o /dev/null

curl -sS -f -b "$COOKIE_JAR" "$BASE_URL/api/tickets/lookups/equipment-catalog"
