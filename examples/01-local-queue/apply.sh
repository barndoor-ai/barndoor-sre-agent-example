#!/usr/bin/env bash
# Optional: create example 1's Barndoor configuration with Terraform instead
# of the console (the sre-docker server and the agent's read-only policy).
#
#   ./apply.sh            plan + apply (asks for confirmation)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../scripts/lib.sh
. "$here/../../scripts/lib.sh"
export_terraform_vars

cd "$here/terraform"
terraform init -upgrade -input=false >/dev/null
terraform apply "$@"
