#!/usr/bin/env bash
# Inject a fault into the sample app.
#
#   scripts/break-app.sh overload        flux_capacitor_gigawatts climbs past 1.21
#   scripts/break-app.sh errors [rate]   a share of requests return HTTP 500 (default 0.3)
#   scripts/break-app.sh latency [secs]  every request is delayed (default 1.5s)
#   scripts/break-app.sh crash           the process exits; Docker/Kubernetes restarts it
#   scripts/break-app.sh reset           clear every fault
#   scripts/break-app.sh status          show active faults
#
# APP_URL defaults to http://localhost:8000 (all three examples expose the
# app there).
set -euo pipefail

APP_URL="${APP_URL:-http://localhost:8000}"
fault="${1:?usage: break-app.sh overload|errors [rate]|latency [secs]|crash|reset|status}"

case "$fault" in
  overload) url="$APP_URL/chaos/overload" ;;
  errors)   url="$APP_URL/chaos/errors?rate=${2:-0.3}" ;;
  latency)  url="$APP_URL/chaos/latency?seconds=${2:-1.5}" ;;
  crash)    url="$APP_URL/chaos/crash" ;;
  reset)    url="$APP_URL/chaos/reset" ;;
  status)   curl -sS "$APP_URL/chaos"; echo; exit 0 ;;
  *) echo "unknown fault: $fault" >&2; exit 2 ;;
esac

echo "→ POST $url"
curl -sS -X POST "$url"
echo
