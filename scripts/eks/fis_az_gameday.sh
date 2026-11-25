#!/usr/bin/env bash
# FIS AZ game day for EKS (real AWS, real money).
#
# Simulates the loss of one Availability Zone for the EKS node
# group and measures what happens to the Postgres StatefulSet.
# The experiment template is the one terraform/fis/ builds
# (FIS calling the SSM Resilience Hub document
# AWSResilienceHub-SimulateAzOutageInAsgTest_2020-07-23 against
# the node-group ASG); the driver applies that module before
# this script runs, so this script only starts the experiment
# and measures it. See docs/FIS_AZ_GAMEDAY.md for the runbook,
# stop conditions, and rollback.
#
# Expected outcome: the Postgres pod does NOT recover during
# the experiment. EBS is AZ-bound, so the volume cannot attach
# in another AZ, and the guard cannot fix that either. The
# point is to confirm that expectation and measure the
# client-visible outage, not to be surprised by it. After the
# experiment rolls back (instances restart), the pod recovers
# in its own AZ and the row must read back — a missing or
# changed row is data loss, not a slow recovery.
#
# The SSM document picks the AZ itself (it takes no AZ
# parameter), so the Postgres node is not guaranteed to be in
# the affected AZ. The script records which AZ lost instances
# and whether the Postgres node was in it; if it was not, the
# game day did not test the pod, and the evidence says so.
#
# Cost: $0.10 per action-minute (one action, test duration in
# minutes) plus the EKS cluster cost for the day.
# Results go to evidence/dr-az-gameday.json.
#
# Run by scripts/eks/run_eks_day.sh on the one-day EKS run.
# Manual dispatch only; never run against kind.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NS=csi-demo
EVIDENCE="$ROOT/evidence/dr-az-gameday.json"
REGION="${AWS_REGION:-us-west-2}"
CLUSTER="${CLUSTER_NAME:-pscale-csi}"
TEST_DURATION_MINUTES="${FIS_TEST_DURATION_MINUTES:-2}"

KUBECTL="${KUBECTL:-kubectl}"

pod_ready() {
  $KUBECTL -n "$NS" get pod -l app=postgres -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "gone"
}

run_test_job() {
  $KUBECTL delete job csi-test-write -n "$NS" --ignore-not-found >/dev/null
  $KUBECTL apply -f "$ROOT/k8s/test-job.yaml" >/dev/null
  $KUBECTL -n "$NS" wait --for=condition=complete job/csi-test-write --timeout=180s >/dev/null
  $KUBECTL -n "$NS" logs job/csi-test-write
}

node_az() {
  $KUBECTL get node "$1" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || true
}

# Evidence is written on EXIT, not just at the end: an
# experiment that fails or a pod that never recovers still
# leaves its measured times behind.
COMPLETED="false"
LAST_ERROR=""
EXP_ID=""; TEMPLATE_ID=""
PG_NODE=""; PG_AZ=""; PG_AFFECTED=""; NOTREADY_AT=""; RECOVERED_DURING="false"
ROW_BACK_AT=""; ROW_INTACT=""; AZ_LOST=""; INSTANCE_COUNT=""
trap 'LAST_ERROR="$BASH_COMMAND (exit $?)"' ERR
write_evidence() {
  mkdir -p "$ROOT/evidence"
  EXP_ID="$EXP_ID" TEMPLATE_ID="$TEMPLATE_ID" PG_NODE="$PG_NODE" PG_AZ="$PG_AZ" \
  PG_AFFECTED="$PG_AFFECTED" NOTREADY_AT="$NOTREADY_AT" RECOVERED_DURING="$RECOVERED_DURING" \
  ROW_BACK_AT="$ROW_BACK_AT" ROW_INTACT="$ROW_INTACT" AZ_LOST="$AZ_LOST" \
  INSTANCE_COUNT="$INSTANCE_COUNT" TEST_DURATION_MINUTES="$TEST_DURATION_MINUTES" \
  COMPLETED="$COMPLETED" LAST_ERROR="$LAST_ERROR" \
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
def boolean(name):
    v = os.environ.get(name, "")
    return {"true": True, "false": False}.get(v)
def text(name):
    v = os.environ.get(name, "")
    return v if v not in ("", "null") else None
az_lost = os.environ.get("AZ_LOST", "")
az_list = sorted(set(az_lost.split())) if az_lost else []
evidence = {
    "scope": "EKS + EBS; FIS AZ-loss game day via SSM Resilience Hub document AWSResilienceHub-SimulateAzOutageInAsgTest_2020-07-23",
    "kubernetes": out("$KUBECTL version 2>/dev/null | head -1"),
    "eks_cluster": os.environ.get("CLUSTER"),
    "region": os.environ.get("REGION"),
    "experiment_template_id": text("TEMPLATE_ID"),
    "experiment_id": text("EXP_ID"),
    "test_duration_minutes": num("TEST_DURATION_MINUTES"),
    "completed": os.environ.get("COMPLETED") == "true",
    "error": os.environ.get("LAST_ERROR") or None,
    "az_lost": az_list,
    "instance_count_in_affected_az": num("INSTANCE_COUNT"),
    "postgres_node": text("PG_NODE"),
    "postgres_az": text("PG_AZ"),
    "postgres_node_affected": boolean("PG_AFFECTED"),
    "time_to_notready_seconds": num("NOTREADY_AT"),
    "pod_recovered_during_experiment": boolean("RECOVERED_DURING"),
    "time_from_experiment_end_to_row_seconds": num("ROW_BACK_AT"),
    "row_intact": boolean("ROW_INTACT"),
    "fis_cost_estimate_usd": round(num("TEST_DURATION_MINUTES") * 0.10, 2) if num("TEST_DURATION_MINUTES") is not None else None,
}
with open(sys.argv[1], "w") as f:
    json.dump(evidence, f, indent=2)
print(open(sys.argv[1]).read())
PY
  echo "evidence written to $EVIDENCE"
}
trap write_evidence EXIT

echo "== setup: FIS template + Postgres on EBS =="
TEMPLATE_ID=$(cd "$ROOT/terraform/fis" && terraform output -raw experiment_template_id)
echo "experiment template: $TEMPLATE_ID"
$KUBECTL -n "$NS" wait --for=condition=ready pod -l app=postgres --timeout=600s >/dev/null
run_test_job
echo "setup: Postgres Ready, row written"

PG_NODE=$($KUBECTL -n "$NS" get pod -l app=postgres -o jsonpath='{.items[0].spec.nodeName}')
PG_AZ=$(node_az "$PG_NODE")
echo "Postgres is on node $PG_NODE in $PG_AZ"
echo "nodes and AZs:"
$KUBECTL get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}'
# Instances in the Postgres AZ (for the evidence count).
INSTANCE_COUNT=$($KUBECTL get nodes -l topology.kubernetes.io/zone="$PG_AZ" --no-headers 2>/dev/null | wc -l | tr -d ' ')

echo "== start the AZ-loss experiment =="
EXP_START=$(date +%s)
EXP_ID=$(aws fis start-experiment --region "$REGION" --experiment-template-id "$TEMPLATE_ID" --query 'experiment.id' --output text)
echo "experiment $EXP_ID started"

# Poll the pod and the nodes until the experiment completes
# (or 30 min). The SSM document stops the AZ's instances for
# the test duration, then rolls back on its own.
AFFECTED_NODES=""
END_AT=""
while [ $(( $(date +%s) - EXP_START )) -lt 1800 ]; do
  STATUS=$(aws fis get-experiment --region "$REGION" --id "$EXP_ID" --query 'experiment.state.status' --output text 2>/dev/null || echo "?")
  READY=$(pod_ready)
  if [ -z "$NOTREADY_AT" ] && [ "$READY" != "True" ]; then
    NOTREADY_AT=$(( $(date +%s) - EXP_START ))
    echo "pod NotReady ${NOTREADY_AT}s after experiment start"
  fi
  if [ -n "$NOTREADY_AT" ] && [ "$READY" = "True" ]; then
    RECOVERED_DURING="true"
    echo "pod recovered during the experiment (unexpected for EBS)"
  fi
  # Nodes that go NotReady are in the affected AZ.
  for node in $($KUBECTL get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1}'); do
    case " $AFFECTED_NODES " in
      *" $node "*) ;;
      *) AFFECTED_NODES="$AFFECTED_NODES $node" ;;
    esac
  done
  if [ "$STATUS" = "completed" ]; then
    END_AT=$(date +%s)
    echo "experiment completed after $((END_AT - EXP_START))s"
    break
  fi
  if [ "$STATUS" = "failed" ] || [ "$STATUS" = "stopped" ]; then
    echo "experiment ended with status $STATUS" >&2
    END_AT=$(date +%s)
    break
  fi
  sleep 5
done
if [ -z "$END_AT" ]; then
  echo "experiment did not complete within 1800s; recording what was measured" >&2
  END_AT=$(date +%s)
fi

# Which AZs lost instances, and was the Postgres node in one?
for node in $AFFECTED_NODES; do
  az=$(node_az "$node")
  if [ -n "$az" ]; then
    case " $AZ_LOST " in
      *" $az "*) ;;
      *) AZ_LOST="$AZ_LOST $az" ;;
    esac
  fi
done
case " $AZ_LOST " in
  *" $PG_AZ "*) PG_AFFECTED="true" ;;
  *) PG_AFFECTED="false" ;;
esac
echo "AZs that lost instances:${AZ_LOST:- none observed}; Postgres node affected: $PG_AFFECTED"
if [ "$PG_AFFECTED" != "true" ]; then
  echo "NOTE: the Postgres node was not in the affected AZ, so this game day did not test the pod." >&2
fi

# After rollback the pod recovers in its own AZ; the row must
# read back. Time from experiment end to the row reading back.
echo "== after rollback: pod recovery + row check =="
if $KUBECTL -n "$NS" wait --for=condition=ready pod -l app=postgres --timeout=600s >/dev/null 2>&1; then
  if run_test_job | grep -q csi-powerscale-proof; then
    ROW_INTACT="true"
    ROW_BACK_AT=$(( $(date +%s) - END_AT ))
    echo "row read back ${ROW_BACK_AT}s after experiment end"
  else
    ROW_INTACT="false"
    echo "row did NOT read back — data loss, not a slow recovery" >&2
  fi
else
  ROW_INTACT="false"
  echo "pod did not become Ready within 600s after the experiment" >&2
fi

COMPLETED="true"
# Evidence is written by the EXIT trap.
