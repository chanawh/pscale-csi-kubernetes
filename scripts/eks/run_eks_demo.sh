#!/usr/bin/env bash
# EKS demo, start to finish: write a row -> EBS snapshot ->
# restore -> expand 10 to 20 GiB -> node drain (the EKS
# counterpart to docker kill on kind) -> verify the row.
# Times the pod recovery after the drain, so the resume
# number is measured, not estimated.
#
# Requires: scripts/eks/deploy_eks.sh already run, kubectl
# pointed at the EKS cluster. The test Job is the same one
# as the PowerScale path (k8s/test-job.yaml): same row,
# 'csi-powerscale-proof', same proof.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

run_test_job() {
  kubectl delete job csi-test-write -n csi-demo --ignore-not-found
  kubectl apply -f "$ROOT/k8s/test-job.yaml"
  kubectl -n csi-demo wait --for=condition=complete job/csi-test-write --timeout=180s
  kubectl -n csi-demo logs job/csi-test-write
}

echo "== Write a row (Postgres on EBS) =="
run_test_job

echo
echo "== EBS snapshot + restore =="
kubectl apply -f "$ROOT/k8s/eks/snapshot-ebs.yaml"
kubectl -n csi-demo wait --for=jsonpath='{.status.readyToUse}'=true volumesnapshot/postgres-ebs-snap --timeout=300s
kubectl -n csi-demo get pvc postgres-data-ebs-restored

echo
echo "== Expand EBS PVC 10 -> 20 GiB =="
kubectl -n csi-demo patch pvc postgres-data-ebs --type merge \
  -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
kubectl -n csi-demo wait --for=jsonpath='{.status.capacity.storage}'=20Gi pvc/postgres-data-ebs --timeout=600s
kubectl -n csi-demo get pvc postgres-data-ebs

echo
echo "== Node drain (EKS node failure) =="
NODE="$(kubectl -n csi-demo get pod -l app=postgres -o jsonpath='{.items[0].spec.nodeName}')"
echo "Postgres is on node: $NODE"
START="$(date +%s)"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=300s
kubectl -n csi-demo wait --for=condition=ready pod -l app=postgres --timeout=600s
END="$(date +%s)"
NEW_NODE="$(kubectl -n csi-demo get pod -l app=postgres -o jsonpath='{.items[0].spec.nodeName}')"
echo "Pod recovery after drain: $((END - START)) seconds (node $NODE -> $NEW_NODE)"
echo "Record this number: it replaces the estimated 'within 5 minutes'."
kubectl uncordon "$NODE"

echo
echo "== Verify the row survived =="
run_test_job

echo
echo "== EFS shared claim check =="
kubectl -n csi-demo get pvc shared-data-efs

echo
echo "== Done: the row survived snapshot, expand, and node drain on EKS =="
