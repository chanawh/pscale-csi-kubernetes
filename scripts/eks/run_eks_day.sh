#!/usr/bin/env bash
# One-day EKS run, one command: the driver for the whole flow.
#
#   bash scripts/eks/run_eks_day.sh [--no-destroy] [--skip-fis] [--skip-dr]
#       [--skip-cnpg] [--skip-guard] [--dry-run]
#
# Steps, in order (docs/REAL_EKS_ONE_DAY.md is the runbook;
# this script is the primary path, the manual steps there are
# the fallback):
#   (a) terraform apply: main root (EKS + EFS + guard role +
#       Pod Identity agent) then the FIS module (needs the
#       node-group ASG name, derived from the main apply).
#   (b) deploy the demo: deploy_eks.sh (Terraform re-apply is
#       a no-op here; it then does kubeconfig, snapshot
#       controller, manifests, observability), AZ precondition
#       check, then run_eks_demo.sh (row, snapshot, expand,
#       timed node drain, verify; output teed to
#       evidence/eks-demo-<date>.log).
#   (c) guard live timing: guard_live_eks.sh (CronJob taints,
#       3 trials, evidence/guard-live.json).
#   (d) FIS AZ game day: fis_az_gameday.sh
#       (evidence/dr-az-gameday.json).
#   (e) cross-region DR restore: dr_region_restore.sh
#       (evidence/dr-region.json).
#   (f) CNPG failover: cnpg_failover_eks.sh
#       (evidence/cnpg-failover.json).
#   (g) destroy: FIS module, then destroy_eks.sh (PVCs first,
#       then terraform destroy, orphan check).
#
# Cost: about $4.50-5.00 for the day (docs/REAL_EKS_ONE_DAY.md).
# The driver never runs anything against kind — this is the
# real-AWS path only. Each step reuses the existing script or
# runbook for that step; the driver only orchestrates.
#
# Failure: the driver stops on the first failure and prints a
# summary of what ran and what did not. A failure still runs
# the destroy (cost protection) unless --no-destroy is given.
# A step that is skipped never runs and is reported as skipped.
#
# Environment:
#   AWS_REGION (default us-west-2), CLUSTER_NAME (default
#   pscale-csi), EKS_NODE_DESIRED_SIZE (default 2; set 3 if
#   the AZ check fails — see below),
#   FIS_CANARY_ALARM (required unless --skip-fis: name of an
#   existing CloudWatch alarm used as the FIS stop condition;
#   the project creates no alarm of its own),
#   FIS_TEST_DURATION_MINUTES (default 2),
#   DR_REGION_B, DR_RESTORE_AZ, DR_KUBE_CONTEXT (all required
#   unless --skip-dr; region B's cluster must already exist).
#
# AZ precondition: the Postgres EBS volume's AZ must have a
# second Ready node, or the pod cannot reschedule to another
# node (EBS is AZ-bound) and the drain demo and the guard
# trials cannot reach Ready. The driver checks this after
# deploy and fails fast with the fix (EKS_NODE_DESIRED_SIZE=3
# re-runs the driver with a third node, about $1.00 more for
# the day) instead of timing out 600s into the demo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REGION="${AWS_REGION:-us-west-2}"
CLUSTER="${CLUSTER_NAME:-pscale-csi}"
NODE_DESIRED_SIZE="${EKS_NODE_DESIRED_SIZE:-2}"
FIS_CANARY_ALARM="${FIS_CANARY_ALARM:-}"
FIS_TEST_DURATION_MINUTES="${FIS_TEST_DURATION_MINUTES:-2}"
DR_REGION_B="${DR_REGION_B:-}"
DR_RESTORE_AZ="${DR_RESTORE_AZ:-}"
DR_KUBE_CONTEXT="${DR_KUBE_CONTEXT:-}"

NO_DESTROY="false"
SKIP_FIS="false"
SKIP_DR="false"
SKIP_CNPG="false"
SKIP_GUARD="false"
DRY_RUN="false"

usage() {
  cat <<EOF
Usage: bash scripts/eks/run_eks_day.sh [flags]

  --no-destroy   skip the destroy at the end (debugging only;
                 the cluster keeps billing ~\$135/month)
  --skip-fis     skip the FIS AZ game day
  --skip-dr      skip the cross-region DR restore
  --skip-cnpg    skip the CNPG failover
  --skip-guard   skip the guard live timing
  --dry-run      print the steps that would run, then exit
  --help         this message

Environment: AWS_REGION (default us-west-2), CLUSTER_NAME
(default pscale-csi), EKS_NODE_DESIRED_SIZE (default 2),
FIS_CANARY_ALARM (required unless --skip-fis),
FIS_TEST_DURATION_MINUTES (default 2), DR_REGION_B,
DR_RESTORE_AZ, DR_KUBE_CONTEXT (all required unless
--skip-dr; region B's cluster must already exist).
EOF
}

for arg in "$@"; do
  case "$arg" in
    --no-destroy) NO_DESTROY="true" ;;
    --skip-fis) SKIP_FIS="true" ;;
    --skip-dr) SKIP_DR="true" ;;
    --skip-cnpg) SKIP_CNPG="true" ;;
    --skip-guard) SKIP_GUARD="true" ;;
    --dry-run) DRY_RUN="true" ;;
    --help) usage; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

# --- step tracking + failure handling ---
STEP_PREFLIGHT="not run"
STEP_TERRAFORM="not run"
STEP_DEPLOY="not run"
STEP_AZCHECK="not run"
STEP_DEMO="not run"
STEP_GUARD="not run"
STEP_FIS="not run"
STEP_DR="not run"
STEP_CNPG="not run"
STEP_DESTROY="not run"
CURRENT_STEP="preflight"
APPLIED="false"
FIS_APPLIED="false"
ASG_NAME=""

print_summary() {
  echo
  echo "== EKS day summary =="
  echo "  cluster: $CLUSTER ($REGION, $NODE_DESIRED_SIZE node(s))"
  echo "  preflight:  $STEP_PREFLIGHT"
  echo "  terraform:  $STEP_TERRAFORM"
  echo "  deploy:     $STEP_DEPLOY"
  echo "  az-check:   $STEP_AZCHECK"
  echo "  demo:       $STEP_DEMO"
  echo "  guard:      $STEP_GUARD"
  echo "  fis:        $STEP_FIS"
  echo "  dr:         $STEP_DR"
  echo "  cnpg:       $STEP_CNPG"
  echo "  destroy:    $STEP_DESTROY"
  echo "  evidence:"
  for f in evidence/guard-live.json evidence/dr-az-gameday.json evidence/dr-region.json evidence/cnpg-failover.json; do
    if [ -f "$ROOT/$f" ]; then echo "    $f"; fi
  done
  for f in "$ROOT"/evidence/eks-demo-*.log; do
    [ -f "$f" ] && echo "    ${f#$ROOT/}"
  done
  if [ "$STEP_DESTROY" != "done" ]; then
    echo "  WARNING: the cluster is still up (~\$135/month). Destroy it with:"
    echo "    bash scripts/eks/destroy_eks.sh"
  fi
  echo "  Check the AWS bill tomorrow and record the real total."
}

run_destroy() {
  # Best-effort destroy of what was applied. Returns 0 only if
  # every destroy that ran succeeded; a failure prints a
  # warning and returns 1 so the caller can report the
  # cluster as still up. Idempotent: safe to call twice.
  local ok="true"
  if [ "$FIS_APPLIED" = "true" ]; then
    echo "== destroy: FIS module =="
    (cd "$ROOT/terraform/fis" && terraform destroy -input=false -auto-approve \
      -var="nodegroup_asg_name=$ASG_NAME" -var="canary_alarm_name=$FIS_CANARY_ALARM" \
      -var="test_duration_minutes=$FIS_TEST_DURATION_MINUTES" \
      -var="region=$REGION" -var="cluster_name=$CLUSTER") \
      || { echo "WARNING: FIS terraform destroy failed; check the AWS console" >&2; ok="false"; }
  fi
  if [ "$APPLIED" = "true" ]; then
    echo "== destroy: EKS lab =="
    bash "$ROOT/scripts/eks/destroy_eks.sh" \
      || { echo "WARNING: destroy_eks.sh failed; check the AWS console" >&2; ok="false"; }
  fi
  [ "$ok" = "true" ]
}

on_error() {
  local rc=$?
  trap - ERR
  set +e
  echo "FAILED at step: $CURRENT_STEP (exit $rc)" >&2
  case "$CURRENT_STEP" in
    preflight) STEP_PREFLIGHT="failed" ;;
    terraform) STEP_TERRAFORM="failed" ;;
    deploy) STEP_DEPLOY="failed" ;;
    az-check) STEP_AZCHECK="failed" ;;
    demo) STEP_DEMO="failed" ;;
    guard) STEP_GUARD="failed" ;;
    fis) STEP_FIS="failed" ;;
    dr) STEP_DR="failed" ;;
    cnpg) STEP_CNPG="failed" ;;
    destroy) STEP_DESTROY="failed" ;;
  esac
  if [ "$NO_DESTROY" != "true" ] && [ "$APPLIED" = "true" ]; then
    echo "Destroying the lab (cost protection)..." >&2
    if run_destroy; then STEP_DESTROY="done"; else STEP_DESTROY="failed"; fi
  elif [ "$APPLIED" = "true" ]; then
    echo "NOT destroying (--no-destroy): the cluster keeps billing." >&2
  fi
  print_summary
  exit "$rc"
}
trap on_error ERR

# --- dry run: print the plan, do not execute ---
if [ "$DRY_RUN" = "true" ]; then
  echo "dry run: no AWS calls, nothing applied. Steps that would run:"
  echo "  cluster: $CLUSTER ($REGION, $NODE_DESIRED_SIZE node(s))"
  echo "  (a) terraform apply (main: EKS + EFS + guard role + Pod Identity agent)"
  if [ "$SKIP_FIS" = "true" ]; then
    echo "  (a) FIS module: skipped (--skip-fis)"
  elif [ -z "$FIS_CANARY_ALARM" ]; then
    echo "  (a) FIS module: WOULD FAIL PREFLIGHT — FIS_CANARY_ALARM is not set"
  else
    echo "  (a) FIS module: apply (canary alarm $FIS_CANARY_ALARM, ${FIS_TEST_DURATION_MINUTES} min)"
  fi
  echo "  (b) deploy_eks.sh, AZ precondition check, run_eks_demo.sh"
  [ "$SKIP_GUARD" = "true" ] && echo "  (c) guard live timing: skipped (--skip-guard)" || echo "  (c) guard live timing: guard_live_eks.sh"
  [ "$SKIP_FIS" = "true" ] && echo "  (d) FIS AZ game day: skipped (--skip-fis)" || echo "  (d) FIS AZ game day: fis_az_gameday.sh"
  if [ "$SKIP_DR" = "true" ]; then
    echo "  (e) cross-region DR: skipped (--skip-dr)"
  elif [ -z "$DR_REGION_B" ] || [ -z "$DR_RESTORE_AZ" ] || [ -z "$DR_KUBE_CONTEXT" ]; then
    echo "  (e) cross-region DR: WOULD FAIL PREFLIGHT — DR_REGION_B, DR_RESTORE_AZ and DR_KUBE_CONTEXT must all be set"
  else
    echo "  (e) cross-region DR: dr_region_restore.sh (region B $DR_REGION_B, AZ $DR_RESTORE_AZ, context $DR_KUBE_CONTEXT)"
  fi
  [ "$SKIP_CNPG" = "true" ] && echo "  (f) CNPG failover: skipped (--skip-cnpg)" || echo "  (f) CNPG failover: cnpg_failover_eks.sh"
  [ "$NO_DESTROY" = "true" ] && echo "  (g) destroy: skipped (--no-destroy; the cluster keeps billing)" || echo "  (g) destroy: FIS module, then destroy_eks.sh"
  exit 0
fi

mkdir -p "$ROOT/evidence"

# --- preflight ---
CURRENT_STEP="preflight"
echo "== preflight =="
for cmd in aws terraform kubectl helm envsubst python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing required command: $cmd" >&2; exit 1; }
done
aws sts get-caller-identity --query 'Account' --output text >/dev/null \
  || { echo "AWS credentials do not work (aws sts get-caller-identity failed)" >&2; exit 1; }
echo "AWS account: $(aws sts get-caller-identity --query 'Account' --output text)"
if [ "$SKIP_FIS" != "true" ] && [ -z "$FIS_CANARY_ALARM" ]; then
  echo "FIS_CANARY_ALARM is not set and --skip-fis was not given." >&2
  echo "The FIS game day needs a CloudWatch alarm as its stop condition (docs/FIS_AZ_GAMEDAY.md);" >&2
  echo "the project creates no alarm of its own. Set FIS_CANARY_ALARM to an existing alarm name, or pass --skip-fis." >&2
  exit 1
fi
if [ "$SKIP_DR" != "true" ]; then
  if [ -z "$DR_REGION_B" ] || [ -z "$DR_RESTORE_AZ" ] || [ -z "$DR_KUBE_CONTEXT" ]; then
    echo "DR_REGION_B, DR_RESTORE_AZ and DR_KUBE_CONTEXT must all be set unless --skip-dr is given." >&2
    echo "Region B's cluster must already exist (docs/DR_REGION.md)." >&2
    exit 1
  fi
  kubectl config get-contexts -o name 2>/dev/null | grep -qx "$DR_KUBE_CONTEXT" \
    || { echo "kube context $DR_KUBE_CONTEXT not found (kubectl config get-contexts)" >&2; exit 1; }
fi
echo "preflight ok: cluster $CLUSTER ($REGION, $NODE_DESIRED_SIZE node(s))"
STEP_PREFLIGHT="done"

# --- (a) terraform apply: main root, then FIS ---
CURRENT_STEP="terraform"
echo "== (a) terraform apply: EKS + EFS + guard role + Pod Identity agent =="
APPLIED="true"
cd "$ROOT/terraform"
terraform init -input=false
terraform apply -input=false -auto-approve \
  -var="enable_eks=true" -var="region=$REGION" \
  -var="cluster_name=$CLUSTER" -var="node_desired_size=$NODE_DESIRED_SIZE"
if [ "$SKIP_FIS" != "true" ]; then
  echo "== (a) terraform apply: FIS module =="
  ASG_NAME=$(aws eks describe-nodegroup --region "$REGION" --cluster-name "$CLUSTER" \
    --nodegroup-name "${CLUSTER}-nodes" \
    --query 'nodegroup.resources.autoScalingGroups[0].name' --output text)
  echo "node-group ASG: $ASG_NAME"
  FIS_APPLIED="true"
  cd "$ROOT/terraform/fis"
  terraform init -input=false
  terraform apply -input=false -auto-approve \
    -var="nodegroup_asg_name=$ASG_NAME" -var="canary_alarm_name=$FIS_CANARY_ALARM" \
    -var="test_duration_minutes=$FIS_TEST_DURATION_MINUTES" \
    -var="region=$REGION" -var="cluster_name=$CLUSTER"
else
  STEP_FIS="skipped"
fi
cd "$ROOT"
STEP_TERRAFORM="done"

# --- (b) deploy the demo ---
CURRENT_STEP="deploy"
echo "== (b) deploy: deploy_eks.sh =="
# deploy_eks.sh re-applies the main terraform (a no-op here);
# it then does kubeconfig, snapshot controller, manifests,
# observability. NODE_DESIRED_SIZE keeps its re-apply in step
# with the driver's apply above.
NODE_DESIRED_SIZE="$NODE_DESIRED_SIZE" bash "$ROOT/scripts/eks/deploy_eks.sh"
STEP_DEPLOY="done"

# AZ precondition: the Postgres volume's AZ must have a second
# Ready node, or the pod cannot reschedule (EBS is AZ-bound)
# and the drain demo and the guard trials cannot reach Ready.
CURRENT_STEP="az-check"
echo "== (b) AZ precondition check =="
VOLUME_ID=$(kubectl -n csi-demo get pvc postgres-data-ebs -o jsonpath='{.spec.volumeName}')
VOLUME_AZ=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$VOLUME_ID" --query 'Volumes[0].AvailabilityZone' --output text)
echo "Postgres volume $VOLUME_ID is in $VOLUME_AZ"
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}'
SAME_AZ_NODES=$(kubectl get nodes -l topology.kubernetes.io/zone="$VOLUME_AZ" --no-headers 2>/dev/null | awk '$2 == "Ready" {n++} END {print n+0}')
if [ "$SAME_AZ_NODES" -lt 2 ]; then
  echo "ERROR: only $SAME_AZ_NODES Ready node(s) in $VOLUME_AZ." >&2
  echo "The Postgres pod cannot reschedule to another AZ (EBS is AZ-bound), so the drain demo and the guard trials cannot reach Ready on this layout." >&2
  echo "Fix: re-run with a second node in $VOLUME_AZ, e.g. EKS_NODE_DESIRED_SIZE=3 bash scripts/eks/run_eks_day.sh (about \$1.00 more for the day)." >&2
  exit 1
fi
echo "precondition ok: $SAME_AZ_NODES Ready nodes in $VOLUME_AZ"
STEP_AZCHECK="done"

CURRENT_STEP="demo"
echo "== (b) demo: run_eks_demo.sh =="
DEMO_LOG="$ROOT/evidence/eks-demo-$(date +%F).log"
bash "$ROOT/scripts/eks/run_eks_demo.sh" 2>&1 | tee "$DEMO_LOG"
echo "demo output saved to $DEMO_LOG (record the pod recovery time from it)"
STEP_DEMO="done"

# --- (c) guard live timing ---
CURRENT_STEP="guard"
if [ "$SKIP_GUARD" = "true" ]; then
  STEP_GUARD="skipped"
else
  echo "== (c) guard live timing =="
  bash "$ROOT/scripts/eks/guard_live_eks.sh"
  STEP_GUARD="done"
fi

# --- (d) FIS AZ game day ---
CURRENT_STEP="fis"
if [ "$SKIP_FIS" = "true" ]; then
  STEP_FIS="skipped"
else
  echo "== (d) FIS AZ game day =="
  bash "$ROOT/scripts/eks/fis_az_gameday.sh"
  STEP_FIS="done"
fi

# --- (e) cross-region DR restore ---
CURRENT_STEP="dr"
if [ "$SKIP_DR" = "true" ]; then
  STEP_DR="skipped"
else
  echo "== (e) cross-region DR restore =="
  DR_VOLUME_ID=$(kubectl -n csi-demo get pvc postgres-data-ebs -o jsonpath='{.spec.volumeName}')
  REGION_A="$REGION" REGION_B="$DR_REGION_B" RESTORE_AZ="$DR_RESTORE_AZ" \
    VOLUME_ID="$DR_VOLUME_ID" KUBE_CONTEXT="$DR_KUBE_CONTEXT" \
    bash "$ROOT/scripts/eks/dr_region_restore.sh"
  STEP_DR="done"
fi

# --- (f) CNPG failover ---
CURRENT_STEP="cnpg"
if [ "$SKIP_CNPG" = "true" ]; then
  STEP_CNPG="skipped"
else
  echo "== (f) CNPG failover =="
  bash "$ROOT/scripts/eks/cnpg_failover_eks.sh"
  STEP_CNPG="done"
fi

# --- (g) destroy ---
CURRENT_STEP="destroy"
if [ "$NO_DESTROY" = "true" ]; then
  STEP_DESTROY="skipped"
  echo "NOT destroying (--no-destroy): the cluster keeps billing ~\$135/month." >&2
else
  echo "== (g) destroy =="
  if run_destroy; then
    STEP_DESTROY="done"
  else
    STEP_DESTROY="failed"
    print_summary
    exit 1
  fi
fi

print_summary
