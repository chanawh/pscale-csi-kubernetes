#!/usr/bin/env bash
# Node-failure drill for CI (kind + in-cluster NFS).
#
# Three cases, one Postgres StatefulSet, Postgres on the NFS
# claim from k8s/ci-drill/pvc-postgres-nfs.yaml:
#   1. Drain: graceful. The kubelet is alive, so the pod
#      terminates cleanly and the StatefulSet reschedules it.
#      This measures graceful rescheduling, NOT failure.
#   2. Hard stop, no intervention: docker stop the node
#      running Postgres, then watch. Expected result: STALL.
#      The pod stays Terminating on the dead node, because
#      the kubelet that would confirm deletion is gone, and
#      the StatefulSet will not create a replacement with
#      the same name while the old pod exists (at-most-one).
#      A stall here is documented behavior, not a failure
#      of the drill. After the stall is recorded, the node
#      is started again and the pod recovers in place.
#   3. Hard stop + out-of-service taint: docker stop, wait
#      for NotReady (~40s default grace) and eviction start
#      (~40s + 30s toleration), then apply
#      node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
#      (Non-Graceful Node Shutdown, GA since Kubernetes 1.28).
#      The taint force-deletes the pod and detaches its
#      volume immediately, so the StatefulSet can create the
#      replacement on the surviving worker. Recovery is
#      timed from the docker stop to Ready and to serving
#      queries. The node is then restarted and the taint
#      removed.
#
# Scope: kind + NFS only. This does NOT exercise the
# PowerScale CSI driver or OneFS. Results go to
# evidence/node-failure-drill.json. Run by
# .github/workflows/node-failure-drill.yml on GitHub
# runners (which have Docker); it cannot run in this
# build VM, which has no container networking.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NS=csi-demo
EVIDENCE="$ROOT/evidence/node-failure-drill.json"

KUBECTL="${KUBECTL:-kubectl}"

pod_node() {
  $KUBECTL -n "$NS" get pod -l app=postgres -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true
}

pod_phase() {
  $KUBECTL -n "$NS" get pod -l app=postgres -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "gone"
}

pod_ready() {
  $KUBECTL -n "$NS" get pod -l app=postgres -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False"
}

# Run the test job and fail unless the row reads back.
run_test_job() {
  $KUBECTL delete job csi-test-write -n "$NS" --ignore-not-found >/dev/null
  $KUBECTL apply -f "$ROOT/k8s/test-job.yaml" >/dev/null
  $KUBECTL -n "$NS" wait --for=condition=complete job/csi-test-write --timeout=180s >/dev/null
  $KUBECTL -n "$NS" logs job/csi-test-write
}

# Wait until the pod is Ready, or time out (returns 1).
wait_ready() {
  local timeout="$1"
  $KUBECTL -n "$NS" wait --for=condition=ready pod -l app=postgres --timeout="${timeout}s" >/dev/null 2>&1
}

# Wait until the node reports NotReady, or time out.
wait_notready() {
  local node="$1" timeout="$2" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    local ready
    ready=$($KUBECTL get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "?")
    [ "$ready" = "False" ] && return 0
    sleep 5; waited=$((waited + 5))
  done
  return 1
}

echo "== setup: Postgres on NFS =="
$KUBECTL apply -f "$ROOT/k8s/postgres-statefulset.yaml" >/dev/null
$KUBECTL apply -f "$ROOT/k8s/postgres-secret.yaml" >/dev/null
$KUBECTL apply -f "$ROOT/k8s/ci-drill/pvc-postgres-nfs.yaml" >/dev/null
wait_ready 600
run_test_job
echo "setup: Postgres Ready, row written"

CASE1_DRAIN_READY=""; CASE1_DRAIN_SERVING=""
CASE2_STALLED=""; CASE3_TAINT_READY=""; CASE3_TAINT_SERVING=""

echo "== case 1: drain (graceful) =="
NODE=$(pod_node)
echo "Postgres is on node: $NODE"
T0=$(date +%s)
$KUBECTL drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=300s >/dev/null
wait_ready 300
T1=$(date +%s); CASE1_DRAIN_READY=$((T1 - T0))
echo "case 1: Ready in $CASE1_DRAIN_READY seconds (drain start to Ready)"
run_test_job
T2=$(date +%s); CASE1_DRAIN_SERVING=$((T2 - T0))
echo "case 1: serving in $CASE1_DRAIN_SERVING seconds (drain start to serving queries)"
$KUBECTL uncordon "$NODE" >/dev/null
echo "case 1: pod now on $(pod_node)"

echo "== case 2: hard stop, no intervention (expect stall) =="
NODE=$(pod_node)
echo "Postgres is on node: $NODE"
T0=$(date +%s)
docker stop "$NODE" >/dev/null
# Watch for 240s: past NotReady (~40s) and eviction start
# (~40s + 30s toleration). The pod should stay Terminating
# with no Ready replacement.
sleep 240
PHASE=$(pod_phase)
READY=$(pod_ready)
if [ "$PHASE" = "Running" ] && [ "$READY" = "True" ]; then
  # A Ready pod here would mean the replacement appeared
  # without intervention, contradicting StatefulSet
  # at-most-one. Record it, do not claim a stall.
  CASE2_STALLED="false"
  echo "case 2: UNEXPECTED: pod Running+Ready after hard stop with no intervention"
else
  CASE2_STALLED="true"
  echo "case 2: stalled as expected (pod phase $PHASE, Ready $READY after 240s)"
fi
echo "case 2: restarting node $NODE"
docker start "$NODE" >/dev/null
$KUBECTL wait --for=condition=Ready node/"$NODE" --timeout=300s >/dev/null
wait_ready 600
run_test_job
echo "case 2: pod recovered in place after node restart, row intact"

echo "== case 3: hard stop + out-of-service taint =="
NODE=$(pod_node)
echo "Postgres is on node: $NODE"
T0=$(date +%s)
docker stop "$NODE" >/dev/null
wait_notready "$NODE" 90
# Eviction starts at ~40s (NotReady) + 30s (toleration).
# Wait until 75s after the stop, then apply the taint.
ELAPSED=$(( $(date +%s) - T0 ))
[ "$ELAPSED" -lt 75 ] && sleep $((75 - ELAPSED))
$KUBECTL taint nodes "$NODE" node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
wait_ready 300
T1=$(date +%s); CASE3_TAINT_READY=$((T1 - T0))
echo "case 3: Ready in $CASE3_TAINT_READY seconds (docker stop to Ready)"
run_test_job
T2=$(date +%s); CASE3_TAINT_SERVING=$((T2 - T0))
echo "case 3: serving in $CASE3_TAINT_SERVING seconds (docker stop to serving queries)"
echo "case 3: pod now on $(pod_node)"
echo "case 3: restarting node $NODE and removing the taint"
docker start "$NODE" >/dev/null
$KUBECTL wait --for=condition=Ready node/"$NODE" --timeout=300s >/dev/null
$KUBECTL taint nodes "$NODE" node.kubernetes.io/out-of-service=nodeshutdown:NoExecute- >/dev/null
wait_ready 600
run_test_job
echo "case 3: node back, taint removed, row intact"

mkdir -p "$ROOT/evidence"
python3 - "$EVIDENCE" <<PY
import json, subprocess, sys
def out(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True).strip()
    except subprocess.CalledProcessError:
        return ""
evidence = {
    "scope": "kind + in-cluster NFS (NOT PowerScale CSI, NOT OneFS)",
    "kubernetes": out("$KUBECTL version --short 2>/dev/null | head -1"),
    "kind": out("kind version 2>/dev/null"),
    "cases": {
        "drain_graceful": {
            "ready_seconds": $CASE1_DRAIN_READY,
            "serving_seconds": $CASE1_DRAIN_SERVING,
        },
        "hard_stop_no_intervention": {
            "stalled": "$CASE2_STALLED" == "true",
            "observed_seconds": 240,
        },
        "hard_stop_out_of_service_taint": {
            "ready_seconds": $CASE3_TAINT_READY,
            "serving_seconds": $CASE3_TAINT_SERVING,
        },
    },
}
with open(sys.argv[1], "w") as f:
    json.dump(evidence, f, indent=2)
print(open(sys.argv[1]).read())
PY
echo "evidence written to $EVIDENCE"
