#!/usr/bin/env bash
# Prove the LLM gateway settings work before starting the agent: one tiny
# Anthropic-style /v1/messages call with the same URL, key and model the
# agent's brain will use.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
require_env LLM_GATEWAY_URL LLM_MODEL ANTHROPIC_AUTH_TOKEN

case "$LLM_GATEWAY_URL" in
  */v1|*/v1/) die "LLM_GATEWAY_URL must not end in /v1; Claude Code appends /v1/messages itself" ;;
esac

echo "→ POST $LLM_GATEWAY_URL/v1/messages (model $LLM_MODEL)"
body="$(LLM_MODEL="$LLM_MODEL" python3 -c 'import json, os; print(json.dumps({"model": os.environ["LLM_MODEL"], "max_tokens": 32, "messages": [{"role": "user", "content": "Reply with exactly: gateway ok"}]}))')"
response="$(curl -sS -w '\n%{http_code}' -X POST "$LLM_GATEWAY_URL/v1/messages" \
  -H "Authorization: Bearer $ANTHROPIC_AUTH_TOKEN" \
  -H 'anthropic-version: 2023-06-01' \
  -H 'Content-Type: application/json' \
  --data "$body")"
status="${response##*$'\n'}"
echo "${response%$'\n'*}"
echo "HTTP $status"
[ "$status" = "200" ] || die "gateway call failed; check the bd- key, that LLM_MODEL matches a name under Available Models, and that the provider behind it is healthy"
