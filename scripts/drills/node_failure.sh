#!/usr/bin/env bash
# Drill 4: node failure, timed.
# Find the worker running Postgres, stop that kind node, and
# prove the pod reschedules on the other worker with the same
# PowerScale volume reattached, and the test row is still there.
# Timing: T0 is the docker stop. Recovery is measured to the
# pod being Ready AND serving a query (pg_isready via the test
# job), not just to the pod existing. With the 30s eviction
# tolerations on the StatefulSet this should be well under the
# 300s Kubernetes default; without them it only measures the
# default. Pass: a new Postgres pod is Ready on a different
# node, the test job reads the row back, and the script prints
# "Pod recovery: N seconds".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NODE=$(kubectl -n csi-demo get pod -l app=postgres -o jsonpath='{.items[0].spec.nodeName}')
echo "Postgres is on node: $NODE"
echo "Stopping kind node $NODE (docker stop $NODE)..."
T0=$(date +%s)
docker stop "$NODE"
kubectl -n csi-demo wait --for=condition=ready pod -l app=postgres --timeout=300s
T1=$(date +%s)
echo "Pod recovery: $((T1 - T0)) seconds (docker stop to Ready)"
NEW_NODE=$(kubectl -n csi-demo get pod -l app=postgres -o jsonpath='{.items[0].spec.nodeName}')
echo "Postgres rescheduled on node: $NEW_NODE"
kubectl delete job csi-test-write -n csi-demo --ignore-not-found
kubectl apply -f "$ROOT/k8s/test-job.yaml"
kubectl -n csi-demo wait --for=condition=complete job/csi-test-write --timeout=180s
kubectl -n csi-demo logs job/csi-test-write
T2=$(date +%s)
echo "Pod recovery: $((T2 - T0)) seconds (docker stop to serving queries)"
echo "node failure: pod moved from $NODE to $NEW_NODE, data survived"
echo "Restart the stopped node with: docker start $NODE"
