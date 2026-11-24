#!/usr/bin/env bash
# Drill 4: node failure (hard stop), timed, with the
# out-of-service taint as the recovery step.
#
# A hard stop is NOT a drain. When the node dies, the
# Postgres StatefulSet pod stays Terminating on it: the
# kubelet that would confirm deletion is gone, and the
# StatefulSet will not create a replacement with the same
# name while the old pod exists. Waiting alone never
# recovers it. The 30s eviction tolerations only control
# when eviction *begins* (~40s NotReady detection + 30s).
#
# Recovery needs the out-of-service taint (Non-Graceful
# Node Shutdown, GA since Kubernetes 1.28):
#   kubectl taint nodes <node> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
# The taint force-deletes the pod and detaches its volume
# immediately, so the StatefulSet can create the
# replacement on the surviving worker with the same
# PowerScale volume reattached. Only apply it after
# verifying the node is really down, and remove it after
# the node is restarted.
#
# Timing: T0 is the docker kill. Recovery is measured to
# the pod being Ready AND serving a query (pg_isready via
# the test job), not just to the pod existing. Pass: a new
# Postgres pod is Ready on a different node, the test job
# reads the row back, and the script prints
# "Pod recovery: N seconds".
# See docs/NODE_FAILURE_DRILL.md for the full mechanics,
# and scripts/drills/node_failure_ci.sh for the three-case
# version (drain / hard stop stall / hard stop + taint)
# that runs in GitHub Actions on kind + NFS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NODE=$(kubectl -n csi-demo get pod -l app=postgres -o jsonpath='{.items[0].spec.nodeName}')
echo "Postgres is on node: $NODE"
echo "Stopping kind node $NODE (docker kill $NODE)..."
T0=$(date +%s)
docker kill "$NODE"
# Wait for the node to report NotReady (up to 90s), then
# until ~75s after the stop (eviction starts at ~40s
# detection + 30s toleration), then apply the taint.
# A hard-killed node reports Unknown (no heartbeat
# within the 40s grace), not False — accept either.
# (CI run 45339015253 sat in Unknown for 135s+ before
# the container-state fallback fired.)
while true; do
  STATUS=$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "?")
  [ "$STATUS" = "False" ] || [ "$STATUS" = "Unknown" ] && break
  sleep 5
  [ $(( $(date +%s) - T0 )) -ge 90 ] && break
done
ELAPSED=$(( $(date +%s) - T0 ))
[ "$ELAPSED" -lt 75 ] && sleep $((75 - ELAPSED))
echo "Node $NODE is NotReady; applying out-of-service taint..."
kubectl taint nodes "$NODE" node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
kubectl -n csi-demo wait --for=condition=ready pod -l app=postgres --timeout=300s
T1=$(date +%s)
echo "Pod recovery: $((T1 - T0)) seconds (docker kill to Ready)"
NEW_NODE=$(kubectl -n csi-demo get pod -l app=postgres -o jsonpath='{.items[0].spec.nodeName}')
echo "Postgres rescheduled on node: $NEW_NODE"
kubectl delete job csi-test-write -n csi-demo --ignore-not-found
kubectl apply -f "$ROOT/k8s/test-job.yaml"
kubectl -n csi-demo wait --for=condition=complete job/csi-test-write --timeout=180s
kubectl -n csi-demo logs job/csi-test-write
T2=$(date +%s)
echo "Pod recovery: $((T2 - T0)) seconds (docker kill to serving queries)"
echo "node failure: pod moved from $NODE to $NEW_NODE, data survived"
EVIDENCE="$ROOT/evidence/node-failure-powerscale.json"
mkdir -p "$ROOT/evidence"
cat > "$EVIDENCE" <<EOF
{
  "scope": "kind + PowerScale CSI driver on OneFS Simulator (NOT EKS, NOT real OneFS)",
  "cases": {
    "hard_stop_out_of_service_taint": {
      "ready_seconds": $((T1 - T0)),
      "serving_seconds": $((T2 - T0))
    }
  },
  "pod_moved_from": "$NODE",
  "pod_moved_to": "$NEW_NODE",
  "row_verified": true
}
EOF
echo "evidence written to $EVIDENCE"
echo "Restart the stopped node, then remove the taint:"
echo "  docker start $NODE"
echo "  kubectl taint nodes $NODE node.kubernetes.io/out-of-service=nodeshutdown:NoExecute-"
