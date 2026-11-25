#!/usr/bin/env bash
# Guard live drill for EKS (real AWS, real money).
#
# The guard, not the script, applies the taint — and on EKS the
# guard runs as the in-cluster CronJob (k8s/guard/, every 2 min,
# --client api --checker aws), not a host-side loop. This script
# applies the guard, verifies one CronJob run completes cleanly
# (proving the pip-installed aws CLI and the Pod Identity
# credentials work in-cluster), then runs 3 live timing trials:
# stop the EC2 instance running Postgres, let the CronJob taint
# it, time stop to taint, to Ready, and to serving. The instance
# is then restarted (or, if the ASG replaced it, the replacement
# node is waited for) and the guard auto-removes its taint when
# the node is Ready again. Results go to
# evidence/guard-live.json, same schema as the kind drill
# (scripts/drills/guard_live_ci.sh) so the EKS number compares
# directly with the kind number and the manual 198s baseline.
#
# Expected as built: stop to serving ~240-360s (median ~300s),
# slower than the manual 198s, because the 180s unreachable
# threshold plus up to 120s of CronJob wait dominate. The
# guard's value as built is automation plus triple
# confirmation, not speed.
#
# No refusal trials: the kind drill pauses a container
# (docker pause), and EC2 has no equivalent of a live but
# frozen instance. The refusal path is covered by the kind
# drill and the guard's unit tests.
#
# Precondition: the Postgres EBS volume's AZ must have a
# second Ready node, or the pod cannot reschedule to another
# node (EBS is AZ-bound) and no trial can reach Ready. The
# script checks this up front and fails fast with the fix
# (a node in the same AZ, e.g. node_desired_size=3).
# The driver (scripts/eks/run_eks_day.sh) checks the same
# thing before the demo; this check is here so the script
# is safe to run standalone.
#
# Run by scripts/eks/run_eks_day.sh on the one-day EKS run.
# Manual dispatch only; never run against kind.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NS=csi-demo
EVIDENCE="$ROOT/evidence/guard-live.json"
REGION="${AWS_REGION:-us-west-2}"
CLUSTER="${CLUSTER_NAME:-pscale-csi}"
GUARD_THRESHOLD=180
GUARD_CADENCE=120
MANUAL_BASELINE_SERVING=198
AUDIT_ALL="$(mktemp)"

KUBECTL="${KUBECTL:-kubectl}"

pod_node() {
  $KUBECTL -n "$NS" get pod -l app=postgres -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true
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
try:
    taints = json.load(sys.stdin).get('spec', {}).get('taints', []) or []
except Exception:
    taints = []
print('yes' if any(t.get('key') == 'node.kubernetes.io/out-of-service' for t in taints) else '')
" 2>/dev/null
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

# EC2 instance id for a node, from its providerID
# (aws:///<az>/<instance-id>).
instance_id_for_node() {
  $KUBECTL get node "$1" -o jsonpath='{.spec.providerID}' 2>/dev/null | sed 's|.*/||'
}

# AZ of a node.
node_az() {
  $KUBECTL get node "$1" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || true
}

# Wait until a node is Ready, or time out (returns 1).
wait_node_ready() {
  local node="$1" timeout="$2" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    local ready
    ready=$($KUBECTL get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "?")
    [ "$ready" = "True" ] && return 0
    sleep 5; waited=$((waited + 5))
  done
  return 1
}

# Wait until at least N nodes are Ready, or time out (returns 1).
wait_nodes_ready() {
  local want="$1" timeout="$2" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    local n
    n=$($KUBECTL get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" {n++} END {print n+0}')
    [ "$n" -ge "$want" ] && return 0
    sleep 5; waited=$((waited + 5))
  done
  return 1
}

# Append new guard audit JSON lines from the CronJob's Job
# pods to $AUDIT_ALL, deduplicated by the whole line. The
# CronJob keeps only the last 3 successful Jobs, so this
# runs right after each taint lands, before the lines age out.
collect_audit_lines() {
  local job line
  for job in $($KUBECTL -n "$NS" get jobs -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep '^node-guard-' || true); do
    $KUBECTL -n "$NS" logs "job/$job" 2>/dev/null | grep -E '^\{"ts":' | while IFS= read -r line; do
      grep -qxF "$line" "$AUDIT_ALL" 2>/dev/null || echo "$line" >> "$AUDIT_ALL"
    done
  done
}

# Latest audit timestamp for a decision on a node, or empty.
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

# Wait for one CronJob run to complete cleanly: a Succeeded
# guard Job pod whose logs contain an audit JSON line. This
# proves the pip-installed aws CLI and the Pod Identity
# credentials work in-cluster before any trial depends on
# them. Returns 1 after 300s (and prints the latest failed
# guard pod's logs for diagnosis).
wait_for_guard_run() {
  local waited=0
  while [ "$waited" -lt 300 ]; do
    collect_audit_lines
    if [ -s "$AUDIT_ALL" ]; then
      echo "guard CronJob verified: audit lines present"
      return 0
    fi
    local failed
    failed=$($KUBECTL -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' 2>/dev/null | awk '$1 ~ /^node-guard-/ && $2 == "Failed" {print $1}' | head -1)
    if [ -n "$failed" ]; then
      echo "guard CronJob pod $failed failed; its logs:" >&2
      $KUBECTL -n "$NS" logs "$failed" 2>/dev/null | tail -20 >&2 || true
      return 1
    fi
    sleep 10; waited=$((waited + 10))
  done
  echo "guard CronJob did not produce an audit line within 300s" >&2
  echo "Check: kubectl -n $NS get pods -l job-name | kubectl -n $NS logs job/<name>" >&2
  return 1
}

# Restart a stopped instance, or wait for its ASG
# replacement. A stopped instance is still in the ASG, but
# the ASG health check may terminate it and launch a
# replacement while it is stopped; either way the node
# must come back Ready. Then wait for the guard to
# auto-remove its taint (next CronJob pass, up to 2 min);
# remove it manually only if it is still there after 300s.
restart_node() {
  local node="$1" instance="$2"
  local state
  state=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$instance" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "gone")
  if [ "$state" = "terminated" ] || [ "$state" = "gone" ]; then
    echo "instance $instance is $state (ASG replaced it); waiting for 2 Ready nodes"
    wait_nodes_ready 2 600 || { echo "replacement node did not become Ready within 600s" >&2; return 1; }
  else
    echo "starting instance $instance (state $state)"
    aws ec2 start-instances --region "$REGION" --instance-ids "$instance" >/dev/null
    wait_node_ready "$node" 600 || { echo "node $node did not become Ready within 600s" >&2; return 1; }
  fi
  local waited=0
  while [ "$waited" -lt 300 ]; do
    if [ -z "$(node_has_oos_taint "$node")" ]; then
      echo "out-of-service taint removed (guard auto-removal)"
      return 0
    fi
    sleep 10; waited=$((waited + 10))
  done
  echo "taint still present after 300s; removing manually" >&2
  $KUBECTL taint nodes "$node" node.kubernetes.io/out-of-service=nodeshutdown:NoExecute- >/dev/null 2>&1 || true
}

# Evidence is written on EXIT, not just at the end: a trial
# that times out or fails mid-drill still leaves its measured
# trials behind. Partial evidence plus the failing command is
# worth more than no artifact.
COMPLETED="false"
LAST_ERROR=""
trap 'LAST_ERROR="$BASH_COMMAND (exit $?)"' ERR
write_evidence() {
  mkdir -p "$ROOT/evidence"
  LIVE1_TAINT="$LIVE1_TAINT" LIVE1_READY="$LIVE1_READY" LIVE1_SERVING="$LIVE1_SERVING" \
  LIVE2_TAINT="$LIVE2_TAINT" LIVE2_READY="$LIVE2_READY" LIVE2_SERVING="$LIVE2_SERVING" \
  LIVE3_TAINT="$LIVE3_TAINT" LIVE3_READY="$LIVE3_READY" LIVE3_SERVING="$LIVE3_SERVING" \
  COMPLETED="$COMPLETED" LAST_ERROR="$LAST_ERROR" AUDIT_ALL="$AUDIT_ALL" \
  REGION="$REGION" CLUSTER="$CLUSTER" python3 - "$EVIDENCE" <<PY
import json, os, subprocess, sys
def out(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True).strip()
    except subprocess.CalledProcessError:
        return ""
def num(name):
    v = os.environ.get(name, "")
    return int(v) if v not in ("", "null") else None
serving = [num(n) for n in ("LIVE1_SERVING", "LIVE2_SERVING", "LIVE3_SERVING")]
serving = [s for s in serving if s is not None]
median_serving = sorted(serving)[len(serving) // 2] if serving else None
def trial(n):
    p = "LIVE%d" % n
    return {
        "trial": n,
        "kill_to_taint_seconds": num(p + "_TAINT"),
        "kill_to_ready_seconds": num(p + "_READY"),
        "kill_to_serving_seconds": num(p + "_SERVING"),
    }
audit_lines = []
try:
    for line in open(os.environ.get("AUDIT_ALL", "")):
        if line.strip():
            audit_lines.append(json.loads(line))
except (FileNotFoundError, json.JSONDecodeError, OSError):
    pass
evidence = {
    "scope": "EKS + EBS (NOT PowerScale CSI, NOT OneFS); guard live mode, in-cluster CronJob (--client api --checker aws), every 2 min",
    "kubernetes": out("$KUBECTL version 2>/dev/null | head -1"),
    "eks_cluster": os.environ.get("CLUSTER"),
    "region": os.environ.get("REGION"),
    "completed": os.environ.get("COMPLETED") == "true",
    "error": os.environ.get("LAST_ERROR") or None,
    "guard": {
        "unreachable_seconds": 180,
        "cadence_seconds": 120,
        "checker": "aws (EC2 describe-instances)",
        "client": "api (CronJob; the guard runs in-cluster)",
    },
    "live_guard_trials": [trial(1), trial(2), trial(3)],
    "live_guard_median_serving_seconds": median_serving,
    "manual_baseline_serving_seconds": 198,
    "refusal_trials": [],
    "refusals": "not run on EKS (no docker-pause equivalent)",
    "guard_audit_lines": audit_lines,
}
with open(sys.argv[1], "w") as f:
    json.dump(evidence, f, indent=2)
print(open(sys.argv[1]).read())
PY
  echo "evidence written to $EVIDENCE"
  rm -f "$AUDIT_ALL"
}
trap write_evidence EXIT

echo "== setup: guard CronJob + Postgres on EBS =="
$KUBECTL apply -f "$ROOT/k8s/guard/" >/dev/null
wait_ready 600
run_test_job
echo "setup: Postgres Ready, row written"
wait_for_guard_run

# Precondition: the Postgres volume's AZ must have a second
# Ready node, or the pod cannot reschedule (EBS is AZ-bound)
# and no trial can reach Ready. Fail fast with the fix.
VOLUME_ID=$($KUBECTL -n "$NS" get pvc postgres-data-ebs -o jsonpath='{.spec.volumeName}')
VOLUME_AZ=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$VOLUME_ID" --query 'Volumes[0].AvailabilityZone' --output text)
echo "Postgres volume $VOLUME_ID is in $VOLUME_AZ"
SAME_AZ_NODES=$($KUBECTL get nodes -l topology.kubernetes.io/zone="$VOLUME_AZ" --no-headers 2>/dev/null | awk '$2 == "Ready" {n++} END {print n+0}')
if [ "$SAME_AZ_NODES" -lt 2 ]; then
  echo "ERROR: only $SAME_AZ_NODES Ready node(s) in $VOLUME_AZ; the guard cannot recover the pod to another AZ (EBS is AZ-bound)." >&2
  echo "Fix: run the node group with a second node in $VOLUME_AZ (e.g. EKS_NODE_DESIRED_SIZE=3 on the driver), then re-run." >&2
  exit 1
fi
echo "precondition: $SAME_AZ_NODES Ready nodes in $VOLUME_AZ (pod can reschedule)"

LIVE1_TAINT=""; LIVE1_READY=""; LIVE1_SERVING=""
LIVE2_TAINT=""; LIVE2_READY=""; LIVE2_SERVING=""
LIVE3_TAINT=""; LIVE3_READY=""; LIVE3_SERVING=""

for TRIAL in 1 2 3; do
  echo "== trial $TRIAL: guard live timing on EKS (CronJob taints) =="
  NODE=$(pod_node)
  INSTANCE=$(instance_id_for_node "$NODE")
  if [ -z "$INSTANCE" ] || [ "${INSTANCE#i-}" = "$INSTANCE" ]; then
    echo "trial $TRIAL: node $NODE has no EC2 instance id (providerID?) — recording failed" >&2
    eval "LIVE${TRIAL}_TAINT=null"
    continue
  fi
  echo "trial $TRIAL: Postgres is on node $NODE (instance $INSTANCE)"
  T0=$(date +%s)
  aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE" >/dev/null
  echo "trial $TRIAL: stopped instance $INSTANCE"
  if poll_oos_taint "$NODE" 600; then
    T1=$(date +%s)
    collect_audit_lines
    TAINT_TS=$(guard_decision_ts "$AUDIT_ALL" "$NODE" "taint")
    if [ -n "$TAINT_TS" ]; then
      eval "LIVE${TRIAL}_TAINT=$((TAINT_TS - T0))"
      echo "trial $TRIAL: guard taint audit ts ${TAINT_TS} ($((TAINT_TS - T0))s after the stop)"
    else
      eval "LIVE${TRIAL}_TAINT=$((T1 - T0))"
      echo "trial $TRIAL: guard taint observed $((T1 - T0))s after the stop (no audit ts found)"
    fi
    wait_ready 300
    T2=$(date +%s); eval "LIVE${TRIAL}_READY=$((T2 - T0))"
    run_test_job
    T3=$(date +%s); eval "LIVE${TRIAL}_SERVING=$((T3 - T0))"
    echo "trial $TRIAL: Ready $((T2 - T0))s, serving $((T3 - T0))s after the stop"
  else
    echo "trial $TRIAL: NO taint from the guard within 600s — recorded as a failure" >&2
    eval "LIVE${TRIAL}_TAINT=null"
  fi
  echo "trial $TRIAL: restarting node $NODE and removing the taint"
  restart_node "$NODE" "$INSTANCE"
  wait_ready 600
  run_test_job
  echo "trial $TRIAL: node back, taint removed, row intact"
done

COMPLETED="true"
# Evidence is written by the EXIT trap.
