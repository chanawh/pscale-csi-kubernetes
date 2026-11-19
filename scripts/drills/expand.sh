#!/usr/bin/env bash
# Drill 3: expand.
# Grow postgres-data from 10Gi to 20Gi, in place, no recreate.
# Pass: the PVC shows 20Gi and the pod is still running.
# This only works because allowVolumeExpansion: true is set
# on the powerscale StorageClass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
kubectl -n csi-demo patch pvc postgres-data -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
kubectl -n csi-demo wait --for=jsonpath='{.status.capacity.storage}'=20Gi pvc/postgres-data --timeout=180s
kubectl -n csi-demo get pvc postgres-data
echo "expand: postgres-data is now 20Gi"
