#!/usr/bin/env bash
# Fire a fixture alert straight onto the agent's alert/firing queue through
# the event server's ingest webhook: the same call any alert source makes.
#
#   scripts/fire-alert.sh <fixture-name|path>
#   scripts/fire-alert.sh flux-capacitor-overload
#   scripts/fire-alert.sh smoke
#
# Each firing gets a fresh incident_id so repeated runs do not collide with
# the auto-dispatch cooldown or an existing incident record.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

fixture="${1:?usage: fire-alert.sh <fixture-name|path>  (fixtures: $(ls "$REPO_ROOT/fixtures" | sed 's/\.json$//' | tr '\n' ' '))}"
if [ -f "$fixture" ]; then
  payload_file="$fixture"
elif [ -f "$REPO_ROOT/fixtures/$fixture.json" ]; then
  payload_file="$REPO_ROOT/fixtures/$fixture.json"
else
  die "fixture '$fixture' not found in fixtures/"
fi

payload="$(python3 - "$payload_file" <<'PY'
import json, sys, time
doc = json.load(open(sys.argv[1]))
now = time.time()
doc["incident_id"] = f"{doc.get('incident_id', 'FIXTURE')}-{int(now)}"
doc["started_at"] = doc.get("started_at") or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
print(json.dumps(doc))
PY
)"

echo "→ POST $BOBI_INGEST_URL ($(basename "$payload_file"))"
curl -sS -w '\nHTTP %{http_code}\n' -X POST "$BOBI_INGEST_URL" \
  -H "Authorization: Bearer $BOBI_INGEST_TOKEN" \
  -H 'Content-Type: application/json' \
  --data "$payload"
