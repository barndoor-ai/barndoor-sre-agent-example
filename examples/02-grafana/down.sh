#!/usr/bin/env bash
# Stop example 2's containers. Add -v to also delete Grafana's data volume.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../scripts/lib.sh
. "$here/../../scripts/lib.sh"

docker compose -f "$here/docker-compose.yaml" down "$@"
