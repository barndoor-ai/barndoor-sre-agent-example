#!/usr/bin/env bash
# Install the agent package into the repo-local bobi home and run it in the
# foreground. Ctrl-C stops it.
#
#   scripts/agent-up.sh            real run (Claude Code via the Barndoor LLM gateway)
#   scripts/agent-up.sh --stub     bobi's scripted stub brain: checks the
#                                  alert -> dispatch -> workflow wiring with no LLM calls
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

if [ "${1:-}" = "--stub" ]; then
  export BRAIN_KIND=stub BOBI_STUB_BRAIN=1
  export LLM_MODEL="${LLM_MODEL:-stub}"
  export BARNDOOR_CLIENT_ID="${BARNDOOR_CLIENT_ID:-stub}" BARNDOOR_CLIENT_SECRET="${BARNDOOR_CLIENT_SECRET:-stub}"
  echo "→ stub brain: no LLM calls; workflow steps will not produce real findings"
else
  require_env BARNDOOR_CLIENT_ID BARNDOOR_CLIENT_SECRET LLM_MODEL ANTHROPIC_AUTH_TOKEN
  [ -x "$BARNDOOR_BIN" ] || die "barndoor CLI not found at $BARNDOOR_BIN (see docs/barndoor-trial-setup.md)"
  command -v claude >/dev/null 2>&1 || die "Claude Code CLI not found (npm install -g @anthropic-ai/claude-code)"
fi
command -v "$BOBI_BIN" >/dev/null 2>&1 || die "bobi not found (uv tool install 'bobi==0.58.0')"
command -v node >/dev/null 2>&1 || die "node >= 20 not found; bobi's local event server needs it"

# Headless Claude Code ignores its tool permissions in a workspace it has not
# been told to trust, so every turn would silently run without tools. Seed
# the trust flag for the agent's run root in the agent's own config dir.
mkdir -p "$CLAUDE_CONFIG_DIR" "$SRE_INCIDENT_DIR"
TRUST_DIR="$RUN_ROOT" python3 - "$CLAUDE_CONFIG_DIR/.claude.json" <<'PY'
import json, os, sys
from pathlib import Path
cfg = Path(sys.argv[1])
try:
    data = json.loads(cfg.read_text() or "{}")
except (OSError, ValueError):
    data = {}
entry = data.setdefault("projects", {}).setdefault(os.environ["TRUST_DIR"], {})
entry["hasTrustDialogAccepted"] = True
cfg.write_text(json.dumps(data, indent=2) + "\n")
PY

echo "→ installing agent package from agent/ as '$AGENT_NAME' (bobi home: $BOBI_HOME)"
"$BOBI_BIN" agents install "$REPO_ROOT/agent" --name "$AGENT_NAME" --non-interactive

cat <<EOF
→ starting '$AGENT_NAME'
   event server : $BOBI_EVENT_SERVER
   ingest URL   : $BOBI_INGEST_URL
   gateway      : $LLM_GATEWAY_URL (model ${LLM_MODEL:-unset})
   incidents    : $SRE_INCIDENT_DIR
EOF
exec "$BOBI_BIN" agent "$AGENT_NAME" start --foreground
