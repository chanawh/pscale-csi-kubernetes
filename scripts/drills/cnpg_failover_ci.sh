#!/usr/bin/env bash
# CNPG failover drill for CI (kind + in-cluster NFS).
#
# Three failover trials, one CloudNativePG 2-replica
# cluster (k8s/cnpg/cluster.yaml, storageClassName nfs).
# Per trial: docker kill the node running the primary,
# then time kill to the new primary Ready and to serving
# queries against the postgres-cnpg-rw service, on the
# same row the StatefulSet drill uses
# ('csi-powerscale-proof'). The node is then restarted
# and the cluster must return to Ready with the row
# intact; a trial that does not heal is recorded as
# failed in the evidence, not hidden, and the drill
# continues to the next trial.
#
# This is the drill that produces the Version 2 CNPG
# number (see the resume generator docstring): CNPG
# failover seconds (median of 3 trials) against the
# StatefulSet + guard baseline (serving 198s, run
# 45339015253). The kind number is the kind-scoped
# CNPG failover time; the EKS number needs the
# one-day EKS run.
#
# Scope: kind + NFS only. This does NOT exercise the
# PowerScale CSI driver or OneFS. Results go to
# evidence/cnpg-failover.json. Run by
# .github/workflows/cnpg-failover-drill.yml on GitHub
# runners (which have Docker); it cannot run in this
# build VM, which has no container networking.
#
# No expected time is stated anywhere for this drill:
# CNPG promotion time on kind is genuinely unmeasured,
# and stating one would be a guess, not a target.
#
# Two things the ceiling-written runbook got wrong and
# this drill fixes (see docs/CNPG_COMPARISON.md): the
# bootstrap secret must be a kubernetes.io/basic-auth
# secret with username/password keys, username matching
# the owner — the old cluster.yaml pointed at
# postgres-secret, whose keys are POSTGRES_USER and
# friends, and the cluster would never have created.
# k8s/cnpg/secret.yaml is that secret. psql also needs
# PGPASSWORD (read from the secret), and the one-shot
# psql pods need --restart=Never.
#
# Scheduling caveat: the manifest sets no topology
# constraint, so both CNPG pods can land on one worker.
# If the primary and the standby share a node, killing
# it kills the cluster and the trial records failed —
# the setup log prints each pod's node so the run log
# shows whether that happened.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NS=csi-demo
EVIDENCE="$ROOT/evidence/cnpg-failover.json"
CLUSTER=postgres-cnpg
CNPG_VERSION=1.30.1
BASELINE_SERVING=198

KUBECTL="${KUBECTL:-kubectl}"
PGPASSWORD=""

# The pod the operator currently considers primary.
current_primary() {
  $KUBECTL -n "$NS" get cluster "$CLUSTER" -o jsonpath='{.status.currentPrimary}' 2>/dev/null || true
}

pod_node() {
  $KUBECTL -n "$NS" get pod "$1" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true
}

pod_ready() {
  $KUBECTL -n "$NS" get pod "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False"
}

# Wait until the cluster reports Ready, or time out (returns 1).
wait_cluster_ready() {
  local timeout="$1"
  $KUBECTL -n "$NS" wait --for=condition=Ready cluster/"$CLUSTER" --timeout="${timeout}s" >/dev/null 2>&1
}

# One-shot psql pod: run the SQL against the read-write
# service and print stdout. The pod name is unique per
# call so repeated polls never collide with a lingering
# pod from the previous poll. PGCONNECT_TIMEOUT keeps a
# single poll from hanging on a dead endpoint.
psql_rw() {
  local sql="$1"
  $KUBECTL -n "$NS" run "cnpg-psql-$(date +%s%N)" --rm -i --restart=Never \
    --image=postgres:16 --env PGPASSWORD="$PGPASSWORD" --env PGCONNECT_TIMEOUT=10 -- \
    psql -h postgres-cnpg-rw -U postgres -d csi_demo -tAc "$sql" 2>/dev/null
}

# Write the same row the StatefulSet drill uses.
# Retrying: the rw service endpoint can lag the cluster
# reporting Ready, so a single psql attempt can fail on
# a healthy cluster. Retry 5 times, 15s apart; if all
# fail, return 1 and the setup exits (set -e) with the
# error recorded in the evidence.
cnpg_write_row() {
  local sql="CREATE TABLE IF NOT EXISTS csi_proof (id INT PRIMARY KEY, note TEXT); INSERT INTO csi_proof VALUES (1, 'csi-powerscale-proof') ON CONFLICT (id) DO NOTHING; SELECT * FROM csi_proof;"
  local attempt=1
  while [ "$attempt" -le 5 ]; do
    if psql_rw "$sql"; then return 0; fi
    echo "cnpg_write_row: attempt $attempt failed, retrying in 15s" >&2
    sleep 15
    attempt=$((attempt + 1))
  done
  echo "cnpg_write_row: row write failed after 5 attempts" >&2
  return 1
}

# True when the row reads back through the rw service.
cnpg_read_row() {
  psql_rw "SELECT note FROM csi_proof WHERE id=1;" 2>/dev/null | grep -q csi-powerscale-proof
}

# Evidence is written on EXIT, not just at the end: a
# trial that times out or a cluster that never heals
# still leaves its measured trials behind. Partial
# evidence plus the failing command is worth more than
# no artifact.
COMPLETED="false"
LAST_ERROR=""
trap 'LAST_ERROR="$BASH_COMMAND (exit $?)"' ERR
write_evidence() {
  mkdir -p "$ROOT/evidence"
  T1_READY="$T1_READY" T1_SERVING="$T1_SERVING" T1_PRIMARY="$T1_PRIMARY" T1_OLD="$T1_OLD" T1_NODE="$T1_NODE" T1_ROW="$T1_ROW" T1_FAILED="$T1_FAILED" \
  T2_READY="$T2_READY" T2_SERVING="$T2_SERVING" T2_PRIMARY="$T2_PRIMARY" T2_OLD="$T2_OLD" T2_NODE="$T2_NODE" T2_ROW="$T2_ROW" T2_FAILED="$T2_FAILED" \
  T3_READY="$T3_READY" T3_SERVING="$T3_SERVING" T3_PRIMARY="$T3_PRIMARY" T3_OLD="$T3_OLD" T3_NODE="$T3_NODE" T3_ROW="$T3_ROW" T3_FAILED="$T3_FAILED" \
  COMPLETED="$COMPLETED" LAST_ERROR="$LAST_ERROR" python3 - "$EVIDENCE" <<PY
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
serving = [num(n) for n in ("T1_SERVING", "T2_SERVING", "T3_SERVING")]
serving = [s for s in serving if s is not None]
median_serving = sorted(serving)[len(serving) // 2] if serving else None
def trial(n):
    p = "T%d" % n
    return {
        "trial": n,
        "old_primary": text(p + "_OLD"),
        "killed_node": text(p + "_NODE"),
        "new_primary": text(p + "_PRIMARY"),
        "kill_to_ready_seconds": num(p + "_READY"),
        "kill_to_serving_seconds": num(p + "_SERVING"),
        "row_intact": boolean(p + "_ROW"),
        "failed": boolean(p + "_FAILED"),
    }
evidence = {
    "scope": "kind + in-cluster NFS (NOT PowerScale CSI, NOT OneFS); CNPG 1.30.1, 2 replicas (primary + standby), operator-managed failover",
    "cnpg_version": "1.30.1",
    "kubernetes": out("$KUBECTL version 2>/dev/null | head -1"),
    "kind": out("kind version 2>/dev/null"),
    "completed": os.environ.get("COMPLETED") == "true",
    "error": os.environ.get("LAST_ERROR") or None,
    "failover_trials": [trial(1), trial(2), trial(3)],
    "median_serving_seconds": median_serving,
    "statefulset_guard_baseline_serving_seconds": 198,
}
with open(sys.argv[1], "w") as f:
    json.dump(evidence, f, indent=2)
print(open(sys.argv[1]).read())
PY
  echo "evidence written to $EVIDENCE"
}
trap write_evidence EXIT

echo "== setup: CNPG operator + 2-replica cluster on NFS =="
$KUBECTL create namespace "$NS" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
$KUBECTL apply --server-side -f "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/v${CNPG_VERSION}/releases/cnpg-${CNPG_VERSION}.yaml" >/dev/null
$KUBECTL wait --for=condition=Available deployment/cnpg-controller-manager -n cnpg-system --timeout=300s >/dev/null
$KUBECTL apply -f "$ROOT/k8s/cnpg/secret.yaml" >/dev/null
$KUBECTL apply -f "$ROOT/k8s/cnpg/cluster.yaml" >/dev/null
wait_cluster_ready 600
PGPASSWORD=$($KUBECTL -n "$NS" get secret postgres-cnpg-secret -o jsonpath='{.data.password}' | base64 -d)
cnpg_write_row
echo "setup: cluster Ready, row written"
$KUBECTL -n "$NS" get pods -l cnpg.io/cluster="$CLUSTER" -o wide
# RPO baseline (best-effort): the standby replay lag before
# the trials. The archive is not configured on kind (no S3,
# no plugin), so the RPO script records archive: not
# configured and only the failover RPO is measured.
python3 "$ROOT/scripts/drills/rpo_measure.py" --evidence "$ROOT/evidence/rpo-$(date +%F).json" || echo "RPO measurement not available (non-fatal)" >&2

T1_READY=""; T1_SERVING=""; T1_PRIMARY=""; T1_OLD=""; T1_NODE=""; T1_ROW=""; T1_FAILED=""
T2_READY=""; T2_SERVING=""; T2_PRIMARY=""; T2_OLD=""; T2_NODE=""; T2_ROW=""; T2_FAILED=""
T3_READY=""; T3_SERVING=""; T3_PRIMARY=""; T3_OLD=""; T3_NODE=""; T3_ROW=""; T3_FAILED=""

for TRIAL in 1 2 3; do
  echo "== trial $TRIAL: CNPG failover =="
  OLD_PRIMARY=$(current_primary)
  if [ -z "$OLD_PRIMARY" ]; then
    echo "trial $TRIAL: no current primary — cluster is not healthy; recording failed" >&2
    eval "T${TRIAL}_FAILED=true"
    eval "T${TRIAL}_ROW=null"
    continue
  fi
  NODE=$(pod_node "$OLD_PRIMARY")
  if [ -z "$NODE" ]; then
    echo "trial $TRIAL: primary pod $OLD_PRIMARY has no node — recording failed" >&2
    eval "T${TRIAL}_OLD=$OLD_PRIMARY"
    eval "T${TRIAL}_FAILED=true"
    eval "T${TRIAL}_ROW=null"
    continue
  fi
  eval "T${TRIAL}_OLD=$OLD_PRIMARY"
  eval "T${TRIAL}_NODE=$NODE"
  echo "trial $TRIAL: primary is $OLD_PRIMARY on node $NODE"
  echo "trial $TRIAL: pods: $($KUBECTL -n "$NS" get pods -l cnpg.io/cluster="$CLUSTER" -o jsonpath='{range .items[*]}{.metadata.name}={.spec.nodeName} {end}')"
  T0=$(date +%s)
  docker kill "$NODE" >/dev/null
  READY_AT=""; SERVING_AT=""; NEW_PRIMARY=""
  while [ $(( $(date +%s) - T0 )) -lt 600 ]; do
    CANDIDATE=$(current_primary)
    if [ -n "$CANDIDATE" ] && [ "$CANDIDATE" != "$OLD_PRIMARY" ]; then
      NEW_PRIMARY="$CANDIDATE"
      if [ -z "$READY_AT" ] && [ "$(pod_ready "$CANDIDATE")" = "True" ]; then
        READY_AT=$(( $(date +%s) - T0 ))
      fi
      if [ -z "$SERVING_AT" ] && cnpg_read_row; then
        SERVING_AT=$(( $(date +%s) - T0 ))
      fi
      if [ -n "$READY_AT" ] && [ -n "$SERVING_AT" ]; then
        break
      fi
    fi
    sleep 5
  done
  FAILED="false"
  if [ -n "$SERVING_AT" ]; then
    eval "T${TRIAL}_PRIMARY=$NEW_PRIMARY"
    eval "T${TRIAL}_READY=${READY_AT:-null}"
    eval "T${TRIAL}_SERVING=$SERVING_AT"
    echo "trial $TRIAL: new primary $NEW_PRIMARY Ready ${READY_AT:-unknown}s, serving ${SERVING_AT}s after the kill"
  else
    echo "trial $TRIAL: no serving primary within 600s — recording failed" >&2
    if [ -n "$NEW_PRIMARY" ]; then eval "T${TRIAL}_PRIMARY=$NEW_PRIMARY"; fi
    if [ -n "$READY_AT" ]; then eval "T${TRIAL}_READY=$READY_AT"; fi
    FAILED="true"
  fi
  echo "trial $TRIAL: restarting node $NODE"
  docker start "$NODE" >/dev/null
  if wait_cluster_ready 600; then
    if cnpg_read_row; then
      eval "T${TRIAL}_ROW=true"
      echo "trial $TRIAL: cluster Ready, row intact"
    else
      eval "T${TRIAL}_ROW=false"
      FAILED="true"
      echo "trial $TRIAL: cluster Ready but the row did NOT read back — recording failed" >&2
    fi
  else
    eval "T${TRIAL}_ROW=null"
    FAILED="true"
    echo "trial $TRIAL: cluster did NOT return to Ready within 600s — recording failed" >&2
  fi
  eval "T${TRIAL}_FAILED=$FAILED"
done

python3 "$ROOT/scripts/drills/rpo_measure.py" --evidence "$ROOT/evidence/rpo-$(date +%F).json" || echo "RPO measurement not available (non-fatal)" >&2

COMPLETED="true"
# Evidence is written by the EXIT trap.
