#!/usr/bin/env bash
# Container entrypoint for the SRE agent (adapted from Barndoor's production
# agent): write a kubeconfig from the pod's service account, seed Claude Code
# workspace trust, install the agent package, and run it in the foreground.
set -euo pipefail

log() { echo "sre-agent-entrypoint: $*"; }

if [ "${BRAIN_KIND:-claude}" = "stub" ]; then
  log "stub brain: no LLM calls"
else
  for name in BARNDOOR_CLIENT_ID BARNDOOR_CLIENT_SECRET LLM_MODEL ANTHROPIC_AUTH_TOKEN; do
    [ -n "${!name:-}" ] || { log "missing $name (see the sre-agent Secret)"; exit 1; }
  done
fi

mkdir -p "$BOBI_HOME" "$CLAUDE_CONFIG_DIR" "$SRE_INCIDENT_DIR" "$HOME/.kube"

# The barndoor CLI's embedded Kubernetes server reads a normal kubeconfig.
# Point one context at this cluster's API with the pod's own (read-only)
# service account token. The agent passes kube_context=sre-sandbox.
SA=/var/run/secrets/kubernetes.io/serviceaccount
if [ -r "$SA/token" ]; then
  cat > "$HOME/.kube/config" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: in-cluster
    cluster:
      server: https://kubernetes.default.svc
      certificate-authority: $SA/ca.crt
users:
  - name: sre-agent
    user:
      tokenFile: $SA/token
contexts:
  - name: ${KUBE_CONTEXT:-sre-sandbox}
    context:
      cluster: in-cluster
      user: sre-agent
      namespace: $(cat "$SA/namespace")
current-context: ${KUBE_CONTEXT:-sre-sandbox}
EOF
  export KUBECONFIG="$HOME/.kube/config"
  log "kubeconfig written (context ${KUBE_CONTEXT:-sre-sandbox})"
fi

# Headless Claude Code ignores its tool permissions in an untrusted
# workspace, so every turn would silently run without tools.
RUN_ROOT="$BOBI_HOME/agents/sre/run"
TRUST_DIR="$RUN_ROOT" python3 - "$CLAUDE_CONFIG_DIR/.claude.json" <<'PY'
import json, os, sys
from pathlib import Path
cfg = Path(sys.argv[1])
try:
    data = json.loads(cfg.read_text() or "{}")
except (OSError, ValueError):
    data = {}
data.setdefault("projects", {}).setdefault(os.environ["TRUST_DIR"], {})["hasTrustDialogAccepted"] = True
cfg.write_text(json.dumps(data, indent=2) + "\n")
PY

# Reinstall on every boot so a new image's package replaces the one on the
# persistent volume.
bobi agents install /opt/sre/agent --name sre --non-interactive

log "starting agent (event server on :8080)"
exec bobi agent sre start --foreground
