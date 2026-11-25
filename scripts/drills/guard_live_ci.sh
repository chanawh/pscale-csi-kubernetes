#!/usr/bin/env bash
# Guard live drill for CI (kind + in-cluster NFS).
#
# Two cases, one Postgres StatefulSet, Postgres on the NFS
# claim from k8s/ci-drill/pvc-postgres-nfs.yaml. This is the
# drill that produces the Version 2 guard numbers (see the
# resume generator docstring): the guard, not the script,
# applies the taint, and the guard refusing a live node is
# tested directly.
#
#   A. Live guard timing, 3 trials. docker kill the node
#      running Postgres, then run the guard on a 2-minute
#      cadence — the same cadence as the production CronJob
#      (k8s/guard/cronjob.yaml, schedule */2 * * * *) — and
#      time kill to taint, to Ready, and to serving. The
#      three trials start the guard loop at offsets 0s, 40s,
#      80s so the median samples different CronJob phases.
#      The guard runs host-side (--client kubectl --checker
#      kind): the in-cluster pod has no docker socket, so
#      the kind checker cannot run there. Expected as built:
#      kill to serving ~240-360s (median ~300s) — SLOWER
#      than the manual 198s, because the 180s unreachable
#      threshold plus up to 120s of CronJob wait dominate.
#      The guard's value as built is automation plus triple
#      confirmation, not speed. To beat 198s the loop must
#      be shortened (lower threshold and/or tighter
#      schedule) — a design decision, not taken here.
#   B. Refusal trials, 3 trials. docker pause the node
#      running Postgres: the kubelet freezes, the node goes
#      Unknown, but the container is still alive (docker
#      inspect reports Status "paused"). Run the guard once
#      in LIVE mode and assert it refuses — a refuse-*
#      decision in the audit log and no out-of-service
#      taint on the node — then unpause and verify the pod
#      recovers with its row intact. A taint here would be
#      a wrong taint on a live node, the guard's dangerous
#      failure; the trial records it as a failure.
#
# Scope: kind + NFS only. This does NOT exercise the
# PowerScale CSI driver or OneFS, and it does NOT touch
# EKS (the EKS guard runs as the CronJob with the EC2
# checker; see docs/GUARD_DESIGN.md). Results go to
# evidence/guard-live.json. Run by
# .github/workflows/guard-live-drill.yml on GitHub
# runners (which have Docker); it cannot run in this
# build VM, which has no container networking.
#
# Runtime is ~40-45 minutes: 3 live trials at ~7-8 min
# each (mostly the 180s threshold plus the CronJob
# cadence) and 3 refusal trials at ~4-5 min each
# (mostly the 180s threshold). Manual dispatch only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NS=csi-demo
EVIDENCE="$ROOT/evidence/guard-live.json"
GUARD_THRESHOLD=180
GUARD_CADENCE=120
MANUAL_BASELINE_SERVING=198

KUBECTL="${KUBECTL:-kubectl}"
GUARD_PID=""

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
# Accepts Unknown as well as False: after a hard kill or
# a pause the node goes Unknown (no heartbeat within the
# 40s grace) and may never report False.
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

# True when the node carries the out-of-service taint.
node_has_oos_taint() {
  $KUBECTL get node "$1" -o json 2>/dev/null | python3 -c "
import json, sys
taints = json.load(sys.stdin).get('spec', {}).get('taints', []) or []
print('yes' if any(t.get('key') == 'node.kubernetes.io/out-of-service' for t in taints) else '')
"
}

# Poll until the out-of-service taint appears on the node,
# or time out (returns 1).
poll_oos_taint() {
  local node="$1" timeout="$2" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if [ -n "$(node_has_oos_taint "$node")" ]; then return 0; fi
    sleep 5; waited=$((waited + 5))
  done
  return 1
}

# One live guard pass, host-side, audit to a file.
# Live mode: it applies the taint when the conditions
# hold. Exit code is ignored by callers: a guard that
# refuses logs the refusal and exits 0; a guard that
# cannot list nodes raises, and the loop retries.
run_guard_once() {
  python3 "$ROOT/guard/node_guard.py" --client kubectl --checker kind \
    --cluster-name pscale-csi --unreachable-seconds "$GUARD_THRESHOLD" \
    --audit-file "$1" >/dev/null 2>&1 || true
}

# Start the guard loop in the background: first pass at
# T0+offset, then one pass every GUARD_CADENCE seconds,
# matching the production CronJob cadence. The loop is
# stopped with stop_guard_loop once the taint lands.
start_guard_loop() {
  local offset="$1" audit="$2"
  (
    sleep "$offset"
    while true; do
      run_guard_once "$audit"
      sleep "$GUARD_CADENCE"
    done
  ) &
  GUARD_PID=$!
}

stop_guard_loop() {
  if [ -n "$GUARD_PID" ]; then
    kill "$GUARD_PID" 2>/dev/null || true
    wait "$GUARD_PID" 2>/dev/null || true
    GUARD_PID=""
  fi
}

# Latest audit timestamp for a decision on a node, or
# empty when the audit file holds no such entry.
guard_decision_ts() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
audit, node, want = sys.argv[1], sys.argv[2], sys.argv[3]
ts = ""
try:
    for line in open(audit):
        if not line.strip():
            continue
        e = json.loads(line)
        if e.get("node") == node and e.get("decision") == want:
            ts = str(e.get("ts", ""))
except FileNotFoundError:
    pass
print(ts)
PY
}

# Latest decision for a node in an audit file, or empty.
guard_decision_for() {
  python3 - "$1" "$2" <<'PY'
import json, sys
audit, node = sys.argv[1], sys.argv[2]
decision = ""
try:
    for line in open(audit):
        if not line.strip():
            continue
        e = json.loads(line)
        if e.get("node") == node:
            decision = e.get("decision", "")
except FileNotFoundError:
    pass
print(decision)
PY
}

# Evidence is written on EXIT, not just at the end: a
# trial that times out or fails mid-drill still leaves
# its measured trials behind. Partial evidence plus the
# failing command is worth more than no artifact.
COMPLETED="false"
LAST_ERROR=""
trap 'LAST_ERROR="$BASH_COMMAND (exit $?)"' ERR
write_evidence() {
  stop_guard_loop
  mkdir -p "$ROOT/evidence"
  LIVE1_TAINT="$LIVE1_TAINT" LIVE1_READY="$LIVE1_READY" LIVE1_SERVING="$LIVE1_SERVING" \
  LIVE2_TAINT="$LIVE2_TAINT" LIVE2_READY="$LIVE2_READY" LIVE2_SERVING="$LIVE2_SERVING" \
  LIVE3_TAINT="$LIVE3_TAINT" LIVE3_READY="$LIVE3_READY" LIVE3_SERVING="$LIVE3_SERVING" \
  REFUSE1="$REFUSE1" REFUSE2="$REFUSE2" REFUSE3="$REFUSE3" \
  REFUSE_DECISIONS="$REFUSE_DECISIONS" COMPLETED="$COMPLETED" \
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
serving = [num(n) for n in ("LIVE1_SERVING", "LIVE2_SERVING", "LIVE3_SERVING")]
serving = [s for s in serving if s is not None]
median_serving = sorted(serving)[len(serving) // 2] if serving else None
refusals = [boolean(n) for n in ("REFUSE1", "REFUSE2", "REFUSE3")]
refused = sum(1 for r in refusals if r is True)
def trial(prefix):
    return {
        "kill_to_taint_seconds": num(prefix + "_TAINT"),
        "kill_to_ready_seconds": num(prefix + "_READY"),
        "kill_to_serving_seconds": num(prefix + "_SERVING"),
    }
evidence = {
    "scope": "kind + in-cluster NFS (NOT PowerScale CSI, NOT OneFS); guard live mode, host-side loop (--client kubectl --checker kind)",
    "kubernetes": out("$KUBECTL version 2>/dev/null | head -1"),
    "kind": out("kind version 2>/dev/null"),
    "completed": os.environ.get("COMPLETED") == "true",
    "error": os.environ.get("LAST_ERROR") or None,
    "guard": {
        "unreachable_seconds": 180,
        "cadence_seconds": 120,
        "offsets_seconds": [0, 40, 80],
        "checker": "kind (docker inspect State.Status)",
        "client": "kubectl (host-side loop; the in-cluster pod has no docker socket)",
    },
    "live_guard_trials": [
        dict({"trial": 1, "offset_seconds": 0}, **trial("LIVE1")),
        dict({"trial": 2, "offset_seconds": 40}, **trial("LIVE2")),
        dict({"trial": 3, "offset_seconds": 80}, **trial("LIVE3")),
    ],
    "live_guard_median_serving_seconds": median_serving,
    "manual_baseline_serving_seconds": 198,
    "refusal_trials": [
        {"trial": 1, "refused": boolean("REFUSE1")},
        {"trial": 2, "refused": boolean("REFUSE2")},
        {"trial": 3, "refused": boolean("REFUSE3")},
    ],
    "refusal_decisions": (os.environ.get("REFUSE_DECISIONS") or "").split(",") if os.environ.get("REFUSE_DECISIONS") else [],
    "refusals": f"{refused} of 3",
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

LIVE1_TAINT=""; LIVE1_READY=""; LIVE1_SERVING=""
LIVE2_TAINT=""; LIVE2_READY=""; LIVE2_SERVING=""
LIVE3_TAINT=""; LIVE3_READY=""; LIVE3_SERVING=""
REFUSE1=""; REFUSE2=""; REFUSE3=""; REFUSE_DECISIONS=""

# Case A: live guard timing, 3 trials at offsets 0/40/80s.
TRIAL=0
for OFFSET in 0 40 80; do
  TRIAL=$((TRIAL + 1))
  echo "== case A trial $TRIAL: live guard timing (loop offset ${OFFSET}s) =="
  NODE=$(pod_node)
  echo "Postgres is on node: $NODE"
  AUDIT=$(mktemp)
  T0=$(date +%s)
  start_guard_loop "$OFFSET" "$AUDIT"
  docker kill "$NODE" >/dev/null
  if poll_oos_taint "$NODE" 600; then
    T1=$(date +%s)
    eval "LIVE${TRIAL}_TAINT=$((T1 - T0))"
    TAINT_TS=$(guard_decision_ts "$AUDIT" "$NODE" "taint")
    echo "case A trial $TRIAL: guard taint landed $((T1 - T0))s after the kill (guard audit ts ${TAINT_TS:-unknown})"
    wait_ready 300
    T2=$(date +%s); eval "LIVE${TRIAL}_READY=$((T2 - T0))"
    run_test_job
    T3=$(date +%s); eval "LIVE${TRIAL}_SERVING=$((T3 - T0))"
    echo "case A trial $TRIAL: Ready $((T2 - T0))s, serving $((T3 - T0))s after the kill"
  else
    echo "case A trial $TRIAL: NO taint from the guard within 600s — recorded as a failure" >&2
    eval "LIVE${TRIAL}_TAINT=null"
  fi
  stop_guard_loop
  echo "case A trial $TRIAL: restarting node $NODE and removing the taint"
  docker start "$NODE" >/dev/null
  $KUBECTL wait --for=condition=Ready node/"$NODE" --timeout=300s >/dev/null
  $KUBECTL taint nodes "$NODE" node.kubernetes.io/out-of-service=nodeshutdown:NoExecute- >/dev/null 2>&1 || true
  wait_ready 600
  run_test_job
  echo "case A trial $TRIAL: node back, taint removed, row intact"
  rm -f "$AUDIT"
done

# Case B: refusal trials, 3 trials. docker pause freezes the
# kubelet, so the node goes Unknown, but the container is
# still alive (Status "paused": the kind checker returns
# None, "cannot confirm down", and the guard must refuse).
for TRIAL in 1 2 3; do
  echo "== case B trial $TRIAL: guard must refuse a live (paused) node =="
  NODE=$(pod_node)
  echo "Postgres is on node: $NODE"
  AUDIT=$(mktemp)
  docker pause "$NODE" >/dev/null
  if ! wait_notready "$NODE" 120; then
    echo "case B trial $TRIAL: node never went Unknown after pause — aborting trial" >&2
    docker unpause "$NODE" >/dev/null
    eval "REFUSE${TRIAL}=false"
    rm -f "$AUDIT"
    continue
  fi
  # The guard only decides once unreachable_for reaches
  # the 180s threshold. Unknown was observed within 5s
  # of the flip, so 185s of sleep guarantees it; retry
  # once more if the first pass still finds it too short.
  sleep 185
  run_guard_once "$AUDIT"
  DECISION=$(guard_decision_for "$AUDIT" "$NODE")
  if [ "$DECISION" = "skip-unreachable-short" ]; then
    echo "case B trial $TRIAL: guard still sees the node as too recently unreachable; retrying after 60s"
    sleep 60
    run_guard_once "$AUDIT"
    DECISION=$(guard_decision_for "$AUDIT" "$NODE")
  fi
  if [ -n "$(node_has_oos_taint "$NODE")" ]; then
    echo "case B trial $TRIAL: WRONG TAINT — the guard tainted a live node (decision $DECISION)" >&2
    eval "REFUSE${TRIAL}=false"
    $KUBECTL taint nodes "$NODE" node.kubernetes.io/out-of-service=nodeshutdown:NoExecute- >/dev/null 2>&1 || true
  else
    case "$DECISION" in
      refuse-*)
        eval "REFUSE${TRIAL}=true"
        echo "case B trial $TRIAL: guard refused ($DECISION), no taint"
        ;;
      *)
        echo "case B trial $TRIAL: guard did not refuse (decision ${DECISION:-none}), no taint" >&2
        eval "REFUSE${TRIAL}=false"
        ;;
    esac
  fi
  if [ -n "$REFUSE_DECISIONS" ]; then REFUSE_DECISIONS="$REFUSE_DECISIONS,$DECISION"; else REFUSE_DECISIONS="$DECISION"; fi
  docker unpause "$NODE" >/dev/null
  $KUBECTL wait --for=condition=Ready node/"$NODE" --timeout=300s >/dev/null
  wait_ready 600
  run_test_job
  echo "case B trial $TRIAL: node back, row intact"
  rm -f "$AUDIT"
done

COMPLETED="true"
# Evidence is written by the EXIT trap.
