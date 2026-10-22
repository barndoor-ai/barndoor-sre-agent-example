#!/usr/bin/env bash
# Start example 2: app, Prometheus, Grafana, the bridge, and the tunnel.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../scripts/lib.sh
. "$here/../../scripts/lib.sh"

docker compose -f "$here/docker-compose.yaml" up -d --build

echo "→ waiting for Grafana"
for _ in $(seq 1 60); do
  curl -sf http://localhost:3000/api/health >/dev/null && break
  sleep 2
done
curl -sf http://localhost:3000/api/health >/dev/null || die "Grafana did not come up on :3000"

host="$(tunnel_host docker logs sre-example-tunnel)"
cat <<EOF

App:         http://localhost:8000          (faults: scripts/break-app.sh)
Grafana:     http://localhost:3000          (admin / $GRAFANA_ADMIN_PASSWORD)
Public URL:  https://$host   (for Barndoor's Grafana connector)
Bridge logs: docker logs -f sre-example-bridge

Next: $here/apply.sh   (Terraform: Grafana alerting + Barndoor servers and policies)
EOF
