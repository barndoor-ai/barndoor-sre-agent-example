#!/usr/bin/env bash
# Start the sample app and the alerter for example 1.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../scripts/lib.sh
. "$here/../../scripts/lib.sh"

docker compose -f "$here/docker-compose.yaml" up -d --build
cat <<EOF

App:      http://localhost:8000      (faults: scripts/break-app.sh)
Alerter:  docker logs -f sre-example-alerter
Alerts go to $BOBI_INGEST_URL
Start the agent in another terminal with: scripts/agent-up.sh
EOF
