#!/usr/bin/env bash
# Apply example 2's Terraform: Grafana datasource, dashboard, alert rules and
# webhook routing, plus the Barndoor Grafana server and the agent's policy.
#
# Re-run after the tunnel container restarts: its hostname changes, and this
# updates the Barndoor server to the new one.
#
#   ./apply.sh            plan + apply (asks for confirmation)
#   ./apply.sh -auto-approve
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../scripts/lib.sh
. "$here/../../scripts/lib.sh"
export_terraform_vars

TF_VAR_grafana_instance="$(tunnel_host docker logs sre-example-tunnel)"
export TF_VAR_grafana_instance
echo "→ Grafana public hostname: $TF_VAR_grafana_instance"

cd "$here/terraform"
terraform init -upgrade -input=false >/dev/null
terraform apply "$@"

cat <<EOF

Last manual step (Barndoor cannot do this through Terraform yet):
  1. terraform -chdir=$here/terraform output -raw grafana_connector_token
  2. Barndoor console -> Agents -> $TF_VAR_agent_name -> Connections -> sre-grafana -> Connect,
     and paste the token.
EOF
