#!/usr/bin/env bash
# One-time: configure the trial org's LLM gateway for the SRE agent with
# Terraform (Anthropic credential, provider, model, "sre-agent" route, and a
# daily token budget on the agent). The console path is in
# docs/barndoor-trial-setup.md.
#
#   ANTHROPIC_UPSTREAM_API_KEY=sk-ant-... scripts/setup-llm-gateway.sh
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
export_terraform_vars
require_env ANTHROPIC_UPSTREAM_API_KEY
export TF_VAR_anthropic_api_key="$ANTHROPIC_UPSTREAM_API_KEY"
[ -z "${LLM_UPSTREAM_MODEL:-}" ] || export TF_VAR_upstream_model="$LLM_UPSTREAM_MODEL"

cd "$REPO_ROOT/terraform/llm-gateway"
terraform init -upgrade -input=false >/dev/null
terraform apply "$@"

cat <<EOF

Next:
  1. Set LLM_MODEL=$(terraform output -raw llm_model) in .env
  2. Create a gateway key bound to the agent: console -> AI Agents -> <agent> -> ⋮ -> Manage keys
     -> Create new key. Put the bd-... key in .env as ANTHROPIC_AUTH_TOKEN.
  3. scripts/check-gateway.sh
EOF
