#!/usr/bin/env bash
# CNPG failover drill for EKS (real AWS, real money).
#
# Three failover trials, one CloudNativePG 2-replica cluster
# (k8s/cnpg/cluster.yaml with storageClassName ebs-gp3, the
# EKS swap — the checked-in manifest says nfs for the kind
# run, and this script substitutes the class at apply time
# so there is no second manifest to drift). Per trial:
# terminate the EC2 instance running the primary, then time
# the kill to the new primary Ready and to serving queries
# against the postgres-cnpg-rw service, on the same row the
# StatefulSet drill uses ('csi-powerscale-proof'). The node
# group's ASG then replaces the terminated instance and the
# cluster must return to Ready with the row intact; a trial
# that does not heal is recorded as failed in the evidence,
# not hidden, and the drill continues to the next trial.
#
# This is the drill that produces the Version 2 CNPG number
# on EKS (see the resume generator docstring): CNPG failover
# seconds (median of 3 trials) against the StatefulSet +
# guard baseline (serving 198s, run 45339015253). The kind
# number is the kind-scoped CNPG failover time
# (scripts/drills/cnpg_failover_ci.sh); this is the EKS
# number, same schema, so the two compare directly.
# Results go to evidence/cnpg-failover.json.
#
# No expected time is stated anywhere for this drill: CNPG
# promotion time on EKS is genuinely unmeasured, and stating
# one would be a guess, not a target.
#
# Scheduling caveat: the manifest sets no topology
# constraint, so both CNPG pods can land on one worker. If
# the primary and the standby share a node, terminating it
# kills the cluster and the trial records failed — the setup
# log prints each pod's node so the run log shows whether
# that happened.
#
# Terminating a node also affects the StatefulSet Postgres
# (it shares the nodes); it recovers independently via the
# guard, and it is not measured here.
#
# WAL archive (best-effort, EKS only): cert-manager + the
# Barman Cloud Plugin + the ObjectStore
# (k8s/cnpg/objectstore.yaml, bucket from `terraform output
# -raw cnpg_wal_bucket`), then the Cluster gets the plugins
# entry. If any of it fails, the drill continues without
# archiving and the RPO script records the archive as not
# configured — the failover timing does not depend on the
# backup. Requires envsubst (for the bucket substitution)
# and terraform (for the bucket output); both are already
# required by scripts/eks/deploy_eks.sh.
# A base backup is taken after the cluster is Ready with
# the plugin, so point-in-time recovery has a starting
# point; the RPO is measured before the trials (baseline)
# and after them (final) with scripts/drills/rpo_measure.py.
#
# Run by scripts/eks/run_eks_day.sh on the one-day EKS run.
# Manual dispatch only; never run against kind.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NS=csi-demo
EVIDENCE="$ROOT/evidence/cnpg-failover.json"
REGION="${AWS_REGION:-us-west-2}"
CLUSTER_NAME_EKS="${CLUSTER_NAME:-pscale-csi}"
CLUSTER=postgres-cnpg
CNPG_VERSION=1.30.1
BARMAN_PLUGIN_VERSION=0.15.1
CERT_MANAGER_VERSION=1.21.3
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

# EC2 instance id for a node, from its providerID
# (aws:///<az>/<instance-id>).
instance_id_for_node() {
  $KUBECTL get node "$1" -o jsonpath='{.spec.providerID}' 2>/dev/null | sed 's|.*/||'
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
cnpg_write_row() {
  psql_rw "CREATE TABLE IF NOT EXISTS csi_proof (id INT PRIMARY KEY, note TEXT); INSERT INTO csi_proof VALUES (1, 'csi-powerscale-proof') ON CONFLICT (id) DO NOTHING; SELECT * FROM csi_proof;"
}

# True when the row reads back through the rw service.
cnpg_read_row() {
  psql_rw "SELECT note FROM csi_proof WHERE id=1;" 2>/dev/null | grep -q csi-powerscale-proof
}

# Install cert-manager + the Barman Cloud Plugin and apply
# the ObjectStore (k8s/cnpg/objectstore.yaml, bucket from
# the Terraform output). Returns 1 on any failure; the
# caller treats that as "continue without archiving".
# Each step has an explicit || return 1: this function is
# called in an if-condition, where set -e is suppressed,
# so a bare failing command would not stop it.
install_wal_plugin() {
  echo "WAL archive: installing cert-manager $CERT_MANAGER_VERSION"
  $KUBECTL apply -f "https://github.com/cert-manager/cert-manager/releases/download/v${CERT_MANAGER_VERSION}/cert-manager.yaml" >/dev/null || return 1
  $KUBECTL -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s >/dev/null || return 1
  echo "WAL archive: installing Barman Cloud Plugin $BARMAN_PLUGIN_VERSION"
  $KUBECTL apply -f "https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v${BARMAN_PLUGIN_VERSION}/manifest.yaml" >/dev/null || return 1
  $KUBECTL -n cnpg-system rollout status deploy/plugin-barman-cloud --timeout=300s >/dev/null || return 1
  local bucket
  bucket="$(cd "$ROOT/terraform" && terraform output -raw cnpg_wal_bucket 2>/dev/null)" || return 1
  if [ -z "$bucket" ]; then
    echo "WAL archive: terraform output cnpg_wal_bucket is empty" >&2
    return 1
  fi
  echo "WAL archive: ObjectStore to s3://$bucket/postgres-cnpg"
  CNPG_WAL_BUCKET="$bucket" envsubst < "$ROOT/k8s/cnpg/objectstore.yaml" | $KUBECTL apply -f - >/dev/null || return 1
  return 0
}

# Point the Cluster at the ObjectStore (the plugins entry
# the checked-in cluster.yaml deliberately omits, so the
# kind run needs no plugin). The operator restarts the
# instances once when the plugins change; the caller waits
# for Ready afterwards.
enable_wal_archive() {
  $KUBECTL -n "$NS" patch cluster "$CLUSTER" --type=merge -p '{"spec":{"plugins":[{"name":"barman-cloud.cloudnative-pg.io","isWALArchiver":true,"parameters":{"barmanObjectName":"postgres-cnpg-wal"}}]}}' >/dev/null
}

# First base backup through the plugin (k8s/cnpg/backup.yaml).
# Returns 1 when the Backup does not reach Completed in
# 600s; the caller treats that as a warning, not a failure.
take_base_backup() {
  $KUBECTL apply -f "$ROOT/k8s/cnpg/backup.yaml" >/dev/null || return 1
  local waited=0
  while [ "$waited" -lt 600 ]; do
    local phase
    phase=$($KUBECTL -n "$NS" get backup postgres-cnpg-base-1 -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [ "$phase" = "completed" ] && return 0
    [ "$phase" = "failed" ] && return 1
    sleep 10; waited=$((waited + 10))
  done
  return 1
}

# RPO measurement (best-effort): the archive + standby lag.
# Writes evidence/rpo-<date>.json; never fails the drill.
measure_rpo() {
  python3 "$ROOT/scripts/drills/rpo_measure.py" --evidence "$ROOT/evidence/rpo-$(date +%F).json" || echo "RPO measurement not available (non-fatal)" >&2
}

# Evidence is written on EXIT, not just at the end: a trial
# that times out or a cluster that never heals still leaves
# its measured trials behind. Partial evidence plus the
# failing command is worth more than no artifact.
COMPLETED="false"
LAST_ERROR=""
trap 'LAST_ERROR="$BASH_COMMAND (exit $?)"' ERR
write_evidence() {
  mkdir -p "$ROOT/evidence"
  T1_READY="$T1_READY" T1_SERVING="$T1_SERVING" T1_PRIMARY="$T1_PRIMARY" T1_OLD="$T1_OLD" T1_NODE="$T1_NODE" T1_INSTANCE="$T1_INSTANCE" T1_ROW="$T1_ROW" T1_FAILED="$T1_FAILED" \
  T2_READY="$T2_READY" T2_SERVING="$T2_SERVING" T2_PRIMARY="$T2_PRIMARY" T2_OLD="$T2_OLD" T2_NODE="$T2_NODE" T2_INSTANCE="$T2_INSTANCE" T2_ROW="$T2_ROW" T2_FAILED="$T2_FAILED" \
  T3_READY="$T3_READY" T3_SERVING="$T3_SERVING" T3_PRIMARY="$T3_PRIMARY" T3_OLD="$T3_OLD" T3_NODE="$T3_NODE" T3_INSTANCE="$T3_INSTANCE" T3_ROW="$T3_ROW" T3_FAILED="$T3_FAILED" \
  COMPLETED="$COMPLETED" LAST_ERROR="$LAST_ERROR" REGION="$REGION" CLUSTER_NAME_EKS="$CLUSTER_NAME_EKS" python3 - "$EVIDENCE" <<PY
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
        "killed_instance": text(p + "_INSTANCE"),
        "new_primary": text(p + "_PRIMARY"),
        "kill_to_ready_seconds": num(p + "_READY"),
        "kill_to_serving_seconds": num(p + "_SERVING"),
        "row_intact": boolean(p + "_ROW"),
        "failed": boolean(p + "_FAILED"),
    }
evidence = {
    "scope": "EKS + EBS (NOT PowerScale CSI, NOT OneFS); CNPG 1.30.1, 2 replicas (primary + standby), operator-managed failover",
    "cnpg_version": "1.30.1",
    "kubernetes": out("$KUBECTL version 2>/dev/null | head -1"),
    "eks_cluster": os.environ.get("CLUSTER_NAME_EKS"),
    "region": os.environ.get("REGION"),
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

echo "== setup: CNPG operator + 2-replica cluster on EBS =="
$KUBECTL create namespace "$NS" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
$KUBECTL apply --server-side -f "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/v${CNPG_VERSION}/releases/cnpg-${CNPG_VERSION}.yaml" >/dev/null
$KUBECTL wait --for=condition=Available deployment/cnpg-controller-manager -n cnpg-system --timeout=300s >/dev/null
# WAL archive (best-effort): if any of it fails, the drill
# continues without archiving and the RPO script records
# the archive as not configured.
WAL_ARCHIVE="disabled"
if install_wal_plugin; then
  WAL_ARCHIVE="enabled"
  echo "WAL archive: plugin + ObjectStore installed"
else
  echo "WARNING: WAL archive setup failed, continuing without archiving" >&2
fi
$KUBECTL apply -f "$ROOT/k8s/cnpg/secret.yaml" >/dev/null
# The checked-in cluster manifest says storageClass nfs (the
# kind run). EKS swaps it to ebs-gp3 at apply time so there is
# no second manifest to drift.
sed 's/storageClass: nfs/storageClass: ebs-gp3/' "$ROOT/k8s/cnpg/cluster.yaml" | $KUBECTL apply -f - >/dev/null
wait_cluster_ready 600
if [ "$WAL_ARCHIVE" = "enabled" ]; then
  enable_wal_archive
  wait_cluster_ready 600
  echo "WAL archive: cluster patched with the plugin entry"
  if take_base_backup; then
    echo "WAL archive: base backup completed"
  else
    echo "WARNING: base backup did not complete in 600s" >&2
  fi
fi
PGPASSWORD=$($KUBECTL -n "$NS" get secret postgres-cnpg-secret -o jsonpath='{.data.password}' | base64 -d)
cnpg_write_row
echo "setup: cluster Ready, row written"
$KUBECTL -n "$NS" get pods -l cnpg.io/cluster="$CLUSTER" -o wide
measure_rpo

T1_READY=""; T1_SERVING=""; T1_PRIMARY=""; T1_OLD=""; T1_NODE=""; T1_INSTANCE=""; T1_ROW=""; T1_FAILED=""
T2_READY=""; T2_SERVING=""; T2_PRIMARY=""; T2_OLD=""; T2_NODE=""; T2_INSTANCE=""; T2_ROW=""; T2_FAILED=""
T3_READY=""; T3_SERVING=""; T3_PRIMARY=""; T3_OLD=""; T3_NODE=""; T3_INSTANCE=""; T3_ROW=""; T3_FAILED=""

for TRIAL in 1 2 3; do
  echo "== trial $TRIAL: CNPG failover on EKS =="
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
  INSTANCE=$(instance_id_for_node "$NODE")
  if [ -z "$INSTANCE" ] || [ "${INSTANCE#i-}" = "$INSTANCE" ]; then
    echo "trial $TRIAL: node $NODE has no EC2 instance id (providerID?) — recording failed" >&2
    eval "T${TRIAL}_OLD=$OLD_PRIMARY"
    eval "T${TRIAL}_NODE=$NODE"
    eval "T${TRIAL}_FAILED=true"
    eval "T${TRIAL}_ROW=null"
    continue
  fi
  eval "T${TRIAL}_OLD=$OLD_PRIMARY"
  eval "T${TRIAL}_NODE=$NODE"
  eval "T${TRIAL}_INSTANCE=$INSTANCE"
  echo "trial $TRIAL: primary is $OLD_PRIMARY on node $NODE (instance $INSTANCE)"
  echo "trial $TRIAL: pods: $($KUBECTL -n "$NS" get pods -l cnpg.io/cluster="$CLUSTER" -o jsonpath='{range .items[*]}{.metadata.name}={.spec.nodeName} {end}')"
  T0=$(date +%s)
  aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE" >/dev/null
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
  echo "trial $TRIAL: waiting for the ASG replacement node and the cluster to heal"
  if wait_cluster_ready 900; then
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
    echo "trial $TRIAL: cluster did NOT return to Ready within 900s — recording failed" >&2
  fi
  eval "T${TRIAL}_FAILED=$FAILED"
done

measure_rpo
COMPLETED="true"
# Evidence is written by the EXIT trap.
