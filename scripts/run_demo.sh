#!/usr/bin/env bash
# Full demo, start to finish, on kind + OneFS Simulator.
# StorageClass -> PVC -> Postgres -> write a row -> snapshot ->
# restore -> clone -> expand -> node failure -> verify the row.
# Requires: a cluster, the driver installed, OneFS reachable.
# Each drill is also standalone in scripts/drills/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "== StorageClass + snapshot class =="
kubectl apply -f "$ROOT/k8s/storageclass.yaml"
kubectl apply -f "$ROOT/k8s/snapshotclass.yaml"
kubectl get storageclass powerscale
echo
echo "== Postgres on PowerScale =="
kubectl apply -f "$ROOT/k8s/postgres-secret.yaml"
kubectl apply -f "$ROOT/k8s/pvc-postgres.yaml"
kubectl apply -f "$ROOT/k8s/postgres-statefulset.yaml"
kubectl -n csi-demo wait --for=condition=ready pod -l app=postgres --timeout=300s
kubectl -n csi-demo get pvc postgres-data
echo
echo "== Write a row =="
kubectl apply -f "$ROOT/k8s/test-job.yaml"
kubectl -n csi-demo wait --for=condition=complete job/csi-test-write --timeout=180s
kubectl -n csi-demo logs job/csi-test-write
echo
echo "== Drills =="
bash "$ROOT/scripts/drills/snapshot_restore.sh"
bash "$ROOT/scripts/drills/clone.sh"
bash "$ROOT/scripts/drills/expand.sh"
bash "$ROOT/scripts/drills/node_failure.sh"
echo
echo "== Done: the row 'csi-powerscale-proof' survived all four drills =="
