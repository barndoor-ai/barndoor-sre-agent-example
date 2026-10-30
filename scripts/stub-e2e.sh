#!/usr/bin/env bash
# End-to-end check of the alert -> dispatch -> workflow wiring with bobi's
# scripted stub brain (no LLM calls, no Barndoor account).
#
#   scripts/stub-e2e.sh
#
# Starts the agent with `agent-up.sh --stub`, fires fixtures/smoke.json through
# the ingest webhook, then waits for the one observable that proves dispatch:
# a `triage` run in bobi's workflow ledger whose title carries the fixture's
# alert name. The "Auto-dispatching" log line is NOT evidence: bobi logs it
# even when the launch is then skipped (for example a failed `requires` check).
#
# The stub brain cannot produce handoffs, so the run itself ends "failed"; that
# is expected and is not asserted on. Needs bobi (BOBI_BIN) and node >= 20.
set -euo pipefail

# Fresh runtime state per run, so a leftover run from an earlier invocation can
# never satisfy the check, and so bobi (which rewrites managed blocks in
# ~/AGENTS.md and ~/.codex/AGENTS.md) never touches the real home directory.
# Resolve the bobi binary first: HOME is about to change.
bobi_bin="$(command -v "${BOBI_BIN:-bobi}")" || { echo "error: bobi not found (set BOBI_BIN)" >&2; exit 1; }
work="$(mktemp -d)"
isolate_state() {
  export BOBI_BIN="$bobi_bin"
  export HOME="$work/home" CODEX_HOME="$work/home/.codex"
  export BOBI_HOME="$work/bobi" CLAUDE_CONFIG_DIR="$work/claude" SRE_INCIDENT_DIR="$work/incidents"
  mkdir -p "$HOME"
}
isolate_state
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
# lib.sh sources .env, which may override the settings above; set them again.
isolate_state
case "$BOBI_HOME" in
  "$work"/*) ;;
  *) die "BOBI_HOME ($BOBI_HOME) is not under the scratch dir $work" ;;
esac

TIMEOUT="${STUB_E2E_TIMEOUT:-90}"
agent_log="$work/agent.log"
agent_pid=""

# agent.yaml's `requires` probe only checks that $BARNDOOR_BIN is executable,
# and a failed probe blocks dispatch. The stub brain never starts the MCP
# server, so a placeholder executable is enough here.
printf '#!/bin/sh\nexit 0\n' > "$work/barndoor"
chmod +x "$work/barndoor"
export BARNDOOR_BIN="$work/barndoor"

cleanup() {
  status=$?
  # errexit is live inside an EXIT trap; cleanup must run to the end.
  set +e
  if [ "$status" -ne 0 ]; then
    echo "--- agent log ---" >&2
    cat "$agent_log" >&2 || true
    echo "--- workflow runs ---" >&2
    "$BOBI_BIN" agent "$AGENT_NAME" workflows status >&2 || true
  fi
  "$BOBI_BIN" agent "$AGENT_NAME" stop >/dev/null 2>&1 || true
  "$BOBI_BIN" agent "$AGENT_NAME" event-server stop >/dev/null 2>&1 || true
  if [ -n "$agent_pid" ]; then
    kill "$agent_pid" 2>/dev/null
    wait "$agent_pid" 2>/dev/null
  fi
  # bobi installs the package read-only; make it removable first.
  chmod -R u+w "$work" 2>/dev/null
  rm -rf "$work" || true
  return "$status"
}
trap cleanup EXIT

# wait_for <description> <command...>: poll until the command succeeds.
wait_for() {
  local what="$1" deadline=$((SECONDS + TIMEOUT))
  shift
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || die "timed out after ${TIMEOUT}s waiting for: $what"
    if [ -n "$agent_pid" ] && ! kill -0 "$agent_pid" 2>/dev/null; then
      die "agent exited while waiting for: $what"
    fi
    sleep 1
  done
}

# bobi attaches to ANY healthy event server already on the port, so a user's
# real agent could receive the smoke alert and run a real triage. Refuse.
port_probe_rc=0
curl -s -o /dev/null --max-time 2 "http://localhost:$SRE_EVENT_PORT/" || port_probe_rc=$?
[ "$port_probe_rc" -eq 7 ] || die "something already answers on localhost:$SRE_EVENT_PORT (curl rc=$port_probe_rc); stop it or set SRE_EVENT_PORT to a free port"

"$REPO_ROOT/scripts/agent-up.sh" --stub > "$agent_log" 2>&1 &
agent_pid=$!

wait_for "agent ready (auto-dispatch rules loaded)" grep -q "Auto-dispatch reactor loaded with 1 rule" "$agent_log"
wait_for "director session ready" grep -q "Session 'bobi-sre-director' ready" "$agent_log"

# The run's title is rendered from the alert's own fields, so finding the
# fixture's alert name in it proves the fields reached the workflow.
alertname="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["title"])' "$REPO_ROOT/fixtures/smoke.json")"

response="$("$REPO_ROOT/scripts/fire-alert.sh" smoke)"
echo "$response"
case "$response" in
  *'"delivered_to":1'*'HTTP 200'*) ;;
  *) die "ingest webhook did not accept the alert with one subscriber" ;;
esac

triage_run_present() {
  python3 - "$RUN_ROOT/state/workflow/runs" "$alertname" <<'PY'
import glob, json, os, sys
runs_dir, alertname = sys.argv[1:3]
for path in glob.glob(os.path.join(runs_dir, "*.json")):
    with open(path) as handle:
        run = json.load(handle)
    if run.get("workflow_name") == "triage" and alertname in run.get("title", ""):
        sys.exit(0)
sys.exit(1)
PY
}
wait_for "a triage workflow run for alert '$alertname'" triage_run_present

# Cross-check through bobi's public CLI rather than only its on-disk ledger.
# (Captured first: `grep -q` exiting early would EPIPE the producer under pipefail.)
status_out="$("$BOBI_BIN" agent "$AGENT_NAME" workflows status)"
grep -Eq '^[[:space:]]+[0-9a-f]+[[:space:]]+triage[[:space:]]' <<<"$status_out" \
  || die "bobi's workflow status does not list a triage run"

echo "OK: alert '$alertname' was dispatched to the triage workflow"
