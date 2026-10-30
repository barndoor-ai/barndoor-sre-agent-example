# shellcheck shell=bash
# Shared environment for every example. Source it; do not execute it.
#
# Loads ./.env, then keeps all agent runtime state inside this repository so
# the example never touches your global bobi or Claude Code configuration:
#   .bobi/          bobi home (agent install, event-server state, transcripts)
#   .claude-sre/    the agent's own Claude Code config dir
#   incidents/      incident records written by sre-note
#   .state/         generated secrets (the ingest token)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$REPO_ROOT/.env"
  set +a
fi

export AGENT_NAME="${AGENT_NAME:-sre}"
export BOBI_BIN="${BOBI_BIN:-bobi}"
export BOBI_HOME="${BOBI_HOME:-$REPO_ROOT/.bobi}"
export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$REPO_ROOT/.claude-sre}"
export SRE_INCIDENT_DIR="${SRE_INCIDENT_DIR:-$REPO_ROOT/incidents}"
export PATH="$REPO_ROOT/agent/bin:$PATH"
export BARNDOOR_BIN="${BARNDOOR_BIN:-$(command -v barndoor 2>/dev/null || echo /usr/local/bin/barndoor)}"
export BARNDOOR_ENV="${BARNDOOR_ENV:-prod}"
export LLM_GATEWAY_URL="${LLM_GATEWAY_URL:-https://app.barndoor.ai/api/llm-gateway}"

# bobi renders a "communication style" block into ~/AGENTS.md at startup.
# Turning it off (and shipping no package AGENTS.md) keeps the example from
# writing anything into your home directory; the role prompts carry the style.
export BOBI_COMMUNICATION_STYLE="${BOBI_COMMUNICATION_STYLE:-off}"

export SRE_EVENT_PORT="${SRE_EVENT_PORT:-8080}"
export BOBI_EVENT_SERVER="${BOBI_EVENT_SERVER:-http://localhost:$SRE_EVENT_PORT}"
export BOBI_INGEST_URL="${BOBI_INGEST_URL:-$BOBI_EVENT_SERVER/webhooks/ingest/alert/firing}"

# shellcheck disable=SC2034  # used by the scripts that source this file (agent-up.sh)
RUN_ROOT="$BOBI_HOME/agents/$AGENT_NAME/run"

# One ingest token per checkout, generated on first use. bobi's embedded
# event server seeds it from BOBI_ES_INGEST_TOKENS at startup, so there is no
# separate "mint a token" step. The same pattern makes the Grafana -> bridge
# token and the sandbox Grafana admin password.
mkdir -p "$REPO_ROOT/.state"
generated_secret() {
  local file="$REPO_ROOT/.state/$1" prefix="$2"
  if [ ! -s "$file" ]; then
    # On failure, remove the (already created, empty) file and fail, so callers
    # under `set -e` abort instead of exporting an empty secret.
    if ! PREFIX="$prefix" python3 -c 'import os, secrets; print(os.environ["PREFIX"] + secrets.token_hex(24))' > "$file"; then
      rm -f "$file"
      return 1
    fi
    chmod 600 "$file"
  fi
  [ -s "$file" ] || return 1
  cat "$file"
}
BOBI_INGEST_TOKEN="$(generated_secret ingest-token ingt_)"
export BOBI_INGEST_TOKEN
export BOBI_ES_INGEST_TOKENS="alert/firing=$BOBI_INGEST_TOKEN"
BRIDGE_TOKEN="$(generated_secret bridge-token brt_)"
export BRIDGE_TOKEN
if [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
  GRAFANA_ADMIN_PASSWORD="$(generated_secret grafana-admin-password "")"
fi
export GRAFANA_ADMIN_PASSWORD

# Alert sources running in Docker reach the host's event server through
# host.docker.internal. Docker Desktop and Rancher Desktop route that to the
# host's loopback; on Linux the traffic arrives on the bridge interface, so
# listen on all interfaces there (ingest still requires the token).
if [ "$(uname -s)" = "Linux" ]; then
  export BOBI_ES_BIND="${BOBI_ES_BIND:-0.0.0.0}"
fi

die() {
  echo "error: $*" >&2
  exit 1
}

require_env() {
  local missing=()
  for name in "$@"; do
    [ -n "${!name:-}" ] || missing+=("$name")
  done
  [ ${#missing[@]} -eq 0 ] || die "missing settings: ${missing[*]} (copy .env.example to .env and fill them in)"
}

# Map the org-admin Terraform credential from .env onto TF_VAR_* names. The
# Barndoor provider would otherwise read BARNDOOR_CLIENT_ID/SECRET from the
# environment, and in this repo those are the AGENT's credentials.
export_terraform_vars() {
  require_env BARNDOOR_TF_CLIENT_ID BARNDOOR_TF_CLIENT_SECRET BARNDOOR_TF_TOKEN_URL BARNDOOR_ORGANIZATION_ID
  export TF_VAR_barndoor_base_url="${BARNDOOR_TF_BASE_URL:-https://platform.barndoor.ai}"
  export TF_VAR_barndoor_token_url="$BARNDOOR_TF_TOKEN_URL"
  export TF_VAR_barndoor_client_id="$BARNDOOR_TF_CLIENT_ID"
  export TF_VAR_barndoor_client_secret="$BARNDOOR_TF_CLIENT_SECRET"
  export TF_VAR_barndoor_organization_id="$BARNDOOR_ORGANIZATION_ID"
  export TF_VAR_agent_name="${SRE_AGENT_NAME:-SRE Example Agent}"
  export TF_VAR_bridge_token="$BRIDGE_TOKEN"
  export TF_VAR_grafana_admin_password="$GRAFANA_ADMIN_PASSWORD"
}

# The public hostname of a Cloudflare quick tunnel, read from its logs.
# Usage: tunnel_host <command that prints the tunnel's logs>
tunnel_host() {
  local host=""
  for _ in $(seq 1 30); do
    host="$("$@" 2>&1 | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 | sed 's#https://##')" || true
    [ -n "$host" ] && break
    sleep 2
  done
  [ -n "$host" ] || die "no trycloudflare.com hostname in the tunnel logs yet; is the tunnel running?"
  echo "$host"
}
