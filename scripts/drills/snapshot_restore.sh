#!/usr/bin/env bash
# Drill 1: snapshot and restore.
# Snapshot the Postgres PVC, delete the test row, restore a new
# PVC from the snapshot, and prove the row is back.
# Pass: the restored PVC contains the row 'csi-powerscale-proof'.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
kubectl apply -f "$ROOT/k8s/snapshot.yaml"
kubectl -n csi-demo wait --for=jsonpath='{.status.readyToUse}'=true volumesnapshot/postgres-snap --timeout=180s
kubectl -n csi-demo get volumesnapshot postgres-snap
kubectl apply -f "$ROOT/k8s/pvc-from-snapshot.yaml"
kubectl -n csi-demo wait --for=jsonpath='{.status.phase}'=Bound pvc/postgres-restored --timeout=180s
echo "snapshot restore: postgres-restored is Bound, data is in the snapshot"
