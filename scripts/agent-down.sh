#!/usr/bin/env bash
# Stop the agent and its local event server.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

"$BOBI_BIN" agent "$AGENT_NAME" stop || true
"$BOBI_BIN" agent "$AGENT_NAME" event-server stop || true
