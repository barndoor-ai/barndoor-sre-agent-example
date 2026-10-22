#!/usr/bin/env bash
# Print selected settings (after lib.sh has loaded .env and generated the
# tokens) as one JSON object. The Kubernetes example's Tiltfile reads it to
# build its Secrets, so every example shares the same credentials and tokens.
#
#   scripts/print-env-json.sh NAME [NAME...]
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh" >/dev/null

python3 - "$@" <<'PY'
import json, os, sys
print(json.dumps({name: os.environ.get(name, "") for name in sys.argv[1:]}))
PY
