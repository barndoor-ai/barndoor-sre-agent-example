#!/usr/bin/env bash
# Apply example 3's Terraform: Grafana alerting (through Tilt's port-forward
# on :3000) plus the Barndoor Grafana and Kubernetes servers and the agent's
# read-only policies. Re-run whenever the tunnel pod restarts (new hostname)
# or the Grafana pod restarts (it keeps no state).
#
#   ./apply.sh            plan + apply (asks for confirmation)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../scripts/lib.sh
. "$here/../../scripts/lib.sh"
export_terraform_vars

curl -sf http://localhost:3000/api/health >/dev/null || die "Grafana is not reachable on localhost:3000; is 'tilt up' running?"

TF_VAR_grafana_instance="$(tunnel_host kubectl --context kind-sre-example -n sre-demo logs deploy/tunnel)"
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
