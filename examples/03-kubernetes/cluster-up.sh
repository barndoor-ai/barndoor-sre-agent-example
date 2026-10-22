#!/usr/bin/env bash
# Create the kind cluster for example 3 (idempotent).
set -euo pipefail

if kind get clusters 2>/dev/null | grep -qx sre-example; then
  echo "kind cluster sre-example already exists"
else
  kind create cluster --name sre-example
fi
kubectl config use-context kind-sre-example >/dev/null
echo "kubectl context: kind-sre-example. Next: tilt up"
