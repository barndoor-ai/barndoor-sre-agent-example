#!/usr/bin/env bash
# Stop example 1's containers.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../scripts/lib.sh
. "$here/../../scripts/lib.sh"

docker compose -f "$here/docker-compose.yaml" down
