#!/usr/bin/env bash
# Drill 2: clone.
# Create a second, independent PVC from postgres-data.
# Pass: postgres-clone is Bound, and deleting it does not
# touch the original.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
kubectl apply -f "$ROOT/k8s/pvc-clone.yaml"
kubectl -n csi-demo wait --for=jsonpath='{.status.phase}'=Bound pvc/postgres-clone --timeout=180s
kubectl -n csi-demo get pvc postgres-clone
echo "clone: postgres-clone is Bound"
