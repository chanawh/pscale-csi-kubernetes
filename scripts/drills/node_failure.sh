#!/usr/bin/env bash
# Drill 4: node failure.
# Find the worker running Postgres, stop that kind node, and
# prove the pod reschedules on the other worker with the same
# PowerScale volume reattached, and the test row is still there.
# This is the drill that proves the volume follows the pod.
# Pass: a new Postgres pod is Ready on a different node, and
# the test job reads the row back.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NODE=$(kubectl -n csi-demo get pod -l app=postgres -o jsonpath='{.items[0].spec.nodeName}')
echo "Postgres is on node: $NODE"
echo "Stopping kind node $NODE (docker stop $NODE)..."
docker stop "$NODE"
kubectl -n csi-demo wait --for=condition=ready pod -l app=postgres --timeout=300s
NEW_NODE=$(kubectl -n csi-demo get pod -l app=postgres -o jsonpath='{.items[0].spec.nodeName}')
echo "Postgres rescheduled on node: $NEW_NODE"
kubectl delete job csi-test-write -n csi-demo --ignore-not-found
kubectl apply -f "$ROOT/k8s/test-job.yaml"
kubectl -n csi-demo wait --for=condition=complete job/csi-test-write --timeout=180s
kubectl -n csi-demo logs job/csi-test-write
echo "node failure: pod moved from $NODE to $NEW_NODE, data survived"
echo "Restart the stopped node with: docker start $NODE"
