#!/usr/bin/env bash
# Node-failure drill for CI (kind + in-cluster NFS).
#
# Three cases, one Postgres StatefulSet, Postgres on the NFS
# claim from k8s/ci-drill/pvc-postgres-nfs.yaml:
#   1. Drain: graceful. The kubelet is alive, so the pod
#      terminates cleanly and the StatefulSet reschedules it.
#      This measures graceful rescheduling, NOT failure.
#   2. Hard stop, no intervention: docker kill the node
#      running Postgres, then watch. Expected result: STALL.
#      The pod stays Terminating on the dead node, because
#      the kubelet that would confirm deletion is gone, and
#      the StatefulSet will not create a replacement with
#      the same name while the old pod exists (at-most-one).
#      A stall here is documented behavior, not a failure
#      of the drill. After the stall is recorded, the node
#      is started again and the pod recovers in place.
#   3. Hard stop + out-of-service taint: docker kill, wait
#      for NotReady (~40s default grace) and eviction start
#      (~40s + 30s toleration), then apply
#      node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
#      (Non-Graceful Node Shutdown, GA since Kubernetes 1.28).
#      The taint force-deletes the pod and detaches its
#      volume immediately, so the StatefulSet can create the
#      replacement on the surviving worker. Recovery is
#      timed from the docker kill to Ready and to serving
#      queries. The node is then restarted and the taint
#      removed.
#
# Scope: kind + NFS only. This does NOT exercise the
# PowerScale CSI driver or OneFS. Results go to
# evidence/node-failure-drill.json. Run by
# .github/workflows/node-failure-drill.yml on GitHub
# runners (which have Docker); it cannot run in this
# build VM, which has no container networking.
#
# The node is killed with `docker kill`, not `docker stop`:
# on the first Actions run (24 Nov 2026, run 45333538587)
# `docker stop` failed with "tried to kill container, but
# did not receive an exit event" — the daemon could not
# stop the kind node container. SIGKILL is also the more
# faithful hard failure: a power cut, not a graceful
# shutdown. That first run still measured case 1 (drain):
# Ready in 6s, serving in 10s. The second run
# (45336965561) measured case 1 again (Ready 2s, serving
# 5s) and confirmed case 2 (stall, pod Running/Ready
# False after 240s, recovered in place after restart),
# then died in case 3: the node had not reported
# NotReady 90s after the kill. v1.1.5 waits 180s and
# trusts the container state when the flag lags, and
# always writes (partial) evidence via an EXIT trap.
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
# Logs each poll: the 24 Nov 2026 run (45336965561)
# died silently here when the node had not flipped
# within 90s, and the log gave no clue why.
# Accepts Unknown as well as False: after a hard
# kill the node goes Unknown (no heartbeat within
# the 40s grace) and may never report False — run
# 45339015253 sat in Unknown for 135s+ before the
# container-state fallback fired.
wait_notready() {
  local node="$1" timeout="$2" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    local ready
    ready=$($KUBECTL get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "?")
    echo "wait_notready: node $node Ready=$ready (${waited}s/${timeout}s)"
    [ "$ready" = "False" ] || [ "$ready" = "Unknown" ] && return 0
    sleep 5; waited=$((waited + 5))
  done
  return 1
}

# True when the kind node container is actually
# stopped. The NotReady flag can lag the kill by
# more than the 40s grace (API slowness after a
# node restart); the container state is the ground
# truth about whether the kubelet is dead.
node_container_dead() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "false" ]
}

# Evidence is written on EXIT, not just at the end:
# the first two Actions runs died mid-drill (docker
# stop failure, then a NotReady timeout) and took
# their measured cases down with them. Partial
# evidence plus the failing command is worth more
# than no artifact.
COMPLETED="false"
LAST_ERROR=""
trap 'LAST_ERROR="$BASH_COMMAND (exit $?)"' ERR
write_evidence() {
  mkdir -p "$ROOT/evidence"
  CASE1_DRAIN_READY="$CASE1_DRAIN_READY" CASE1_DRAIN_SERVING="$CASE1_DRAIN_SERVING" \
  CASE2_STALLED="$CASE2_STALLED" CASE3_TAINT_READY="$CASE3_TAINT_READY" \
  CASE3_TAINT_SERVING="$CASE3_TAINT_SERVING" COMPLETED="$COMPLETED" \
  CASE2_DELETION_TS="$CASE2_DELETION_TS" CASE2_TOLERATIONS="$CASE2_TOLERATIONS" \
  CASE2_NODE_TAINTS="$CASE2_NODE_TAINTS" \
  LAST_ERROR="$LAST_ERROR" python3 - "$EVIDENCE" <<PY
import json, os, subprocess, sys
def out(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True).strip()
    except subprocess.CalledProcessError:
        return ""
def num(name):
    v = os.environ.get(name, "")
    return int(v) if v not in ("", "null") else None
def boolean(name):
    v = os.environ.get(name, "")
    return {"true": True, "false": False}.get(v)
evidence = {
    "scope": "kind + in-cluster NFS (NOT PowerScale CSI, NOT OneFS)",
    "kubernetes": out("$KUBECTL version 2>/dev/null | head -1"),
    "kind": out("kind version 2>/dev/null"),
    "completed": os.environ.get("COMPLETED") == "true",
    "error": os.environ.get("LAST_ERROR") or None,
    "cases": {
        "drain_graceful": {
            "ready_seconds": num("CASE1_DRAIN_READY"),
            "serving_seconds": num("CASE1_DRAIN_SERVING"),
        },
        "hard_stop_no_intervention": {
            "stalled": boolean("CASE2_STALLED"),
            "observed_seconds": 240,
            "deletion_timestamp": os.environ.get("CASE2_DELETION_TS") or None,
            "tolerations": os.environ.get("CASE2_TOLERATIONS") or None,
            "node_taints": os.environ.get("CASE2_NODE_TAINTS") or None,
        },
        "hard_stop_out_of_service_taint": {
            "ready_seconds": num("CASE3_TAINT_READY"),
            "serving_seconds": num("CASE3_TAINT_SERVING"),
        },
    },
}
with open(sys.argv[1], "w") as f:
    json.dump(evidence, f, indent=2)
print(open(sys.argv[1]).read())
PY
  echo "evidence written to $EVIDENCE"
}
trap write_evidence EXIT

echo "== setup: Postgres on NFS =="
$KUBECTL apply -f "$ROOT/k8s/postgres-statefulset.yaml" >/dev/null
$KUBECTL apply -f "$ROOT/k8s/postgres-secret.yaml" >/dev/null
$KUBECTL apply -f "$ROOT/k8s/ci-drill/pvc-postgres-nfs.yaml" >/dev/null
wait_ready 600
run_test_job
echo "setup: Postgres Ready, row written"

CASE1_DRAIN_READY=""; CASE1_DRAIN_SERVING=""
CASE2_STALLED=""; CASE2_DELETION_TS=""; CASE2_TOLERATIONS=""; CASE2_NODE_TAINTS=""; CASE3_TAINT_READY=""; CASE3_TAINT_SERVING=""

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
docker kill "$NODE" >/dev/null
# Watch for 240s: past NotReady (~40s) and eviction start
# (~40s + 30s toleration). The pod should stay stuck with
# no Ready replacement. Phase reads Running, not
# Terminating: phase is kubelet-reported and the dead
# kubelet never updates it. Whether eviction started is
# decided by deletionTimestamp, recorded below.
sleep 240
# Why is it stuck? Record the evidence that decides
# whether eviction started: the pod's tolerations and
# deletionTimestamp (set when eviction deletes it), and
# the node's taints. Run 45336965561 showed the pod
# Running/NotReady with no replacement and no record of
# whether the 30s tolerations had fired.
CASE2_DELETION_TS=$($KUBECTL -n "$NS" get pod -l app=postgres -o jsonpath='{.items[0].metadata.deletionTimestamp}' 2>/dev/null || echo "")
CASE2_TOLERATIONS=$($KUBECTL -n "$NS" get pod -l app=postgres -o jsonpath='{.items[0].spec.tolerations}' 2>/dev/null || echo "")
CASE2_NODE_TAINTS=$($KUBECTL get node "$NODE" -o jsonpath='{.spec.taints}' 2>/dev/null || echo "")
echo "case 2: deletionTimestamp=${CASE2_DELETION_TS:-none}"
echo "case 2: tolerations=${CASE2_TOLERATIONS:-none}"
echo "case 2: node_taints=${CASE2_NODE_TAINTS:-none}"
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
docker kill "$NODE" >/dev/null
# The NotReady flag can lag the kill (the 24 Nov 2026
# run timed out at 90s with the node still reporting
# Ready). Wait up to 180s, then trust the container
# state: if the container is stopped, the kubelet is
# dead regardless of what the flag says, and the taint
# is safe to apply. If it is still running, fail
# loudly — the kill did not take.
if ! wait_notready "$NODE" 180; then
  if node_container_dead "$NODE"; then
    echo "case 3: node $NODE still reports Ready after 180s, but its container is stopped — proceeding to the taint"
  else
    echo "case 3: node $NODE still Ready after 180s AND its container is still running — docker kill did not take" >&2
    exit 1
  fi
fi
# Eviction starts at ~40s (NotReady) + 30s (toleration).
# Wait until 75s after the stop, then apply the taint.
ELAPSED=$(( $(date +%s) - T0 ))
[ "$ELAPSED" -lt 75 ] && sleep $((75 - ELAPSED))
$KUBECTL taint nodes "$NODE" node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
wait_ready 300
T1=$(date +%s); CASE3_TAINT_READY=$((T1 - T0))
echo "case 3: Ready in $CASE3_TAINT_READY seconds (docker kill to Ready)"
run_test_job
T2=$(date +%s); CASE3_TAINT_SERVING=$((T2 - T0))
echo "case 3: serving in $CASE3_TAINT_SERVING seconds (docker kill to serving queries)"
echo "case 3: pod now on $(pod_node)"
echo "case 3: restarting node $NODE and removing the taint"
docker start "$NODE" >/dev/null
$KUBECTL wait --for=condition=Ready node/"$NODE" --timeout=300s >/dev/null
$KUBECTL taint nodes "$NODE" node.kubernetes.io/out-of-service=nodeshutdown:NoExecute- >/dev/null
wait_ready 600
run_test_job
echo "case 3: node back, taint removed, row intact"

COMPLETED="true"
# Evidence is written by the EXIT trap.
