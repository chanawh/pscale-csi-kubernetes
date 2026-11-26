#!/usr/bin/env bash
# CNPG-vs-single-replica comparison, CI (kind + in-cluster NFS).
#
# The measured trade-off: operator-managed HA Postgres
# (CloudNativePG, 2 replicas) against the single-replica
# StatefulSet the repo already measures, on the same kill
# (docker kill the node), the same row
# ('csi-powerscale-proof'), the same kind cluster. Three
# arms, each measured by the drill that already exists:
#   (a) CNPG HA — scripts/drills/cnpg_failover_ci.sh,
#       3 failover trials, median kill-to-serving.
#   (b) Single replica, manual out-of-service taint —
#       scripts/drills/node_failure_ci.sh, case 3.
#   (c) Single replica, the guard applies the taint —
#       scripts/drills/guard_live_ci.sh. OFF by default:
#       the guard arm takes ~40-45 minutes on its own, so
#       the workflow runs without it; the comparison then
#       reads evidence/guard-live.json if a previous
#       guard-live dispatch wrote it, and records the arm
#       as "not measured" otherwise. Pass --with-guard to
#       run it inline, or dispatch the guard-live drill
#       first and re-run this one with --offline.
#
# The RPO comes from evidence/rpo-<date>.json, written by
# the CNPG drill's RPO measurement (failover RPO from the
# standby replay lag; archive RPO not configured on kind).
#
# The comparison itself is a pure function of the evidence
# files (scripts/drills/ha_compare.py): it runs no cluster
# and invents no numbers. A failed arm is recorded as
# failed, not hidden, and the comparison still builds from
# the arms that ran. Evidence is written on EXIT, not just
# at the end, so a failed arm still leaves a comparison
# behind. Results go to evidence/ha-comparison-<date>.json.
# Run by .github/workflows/ha-comparison-drill.yml on
# GitHub runners (which have Docker); it cannot run in
# this build VM, which has no container networking.
#
# --offline rebuilds the comparison from the evidence
# files already in evidence/ without running any drill.
# That is how the comparison is rebuilt after a separate
# guard-live dispatch, and how it is verified in the VM
# (no kind needed): run with --offline against sample
# evidence and check the table.
#
# No expected result is stated anywhere: which arm is
# fastest is genuinely unmeasured until this runs, and
# the guard arm is expected to be slowest (its 180s
# threshold + 2-minute cadence dominate), which is the
# point — the guard's value is automation plus triple
# confirmation, not speed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EVIDENCE="$ROOT/evidence/ha-comparison-$(date +%F).json"
SCOPE="kind + in-cluster NFS (NOT PowerScale CSI, NOT OneFS); CNPG HA vs single-replica StatefulSet, same kill, same row"

WITH_GUARD="false"
OFFLINE="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --with-guard) WITH_GUARD="true" ;;
    --offline) OFFLINE="true" ;;
    --help)
      echo "Usage: $0 [--with-guard] [--offline]"
      echo "  --with-guard  run the guard-live drill inline (adds ~40-45 min)"
      echo "  --offline     build the comparison from evidence/ without running drills"
      exit 0
      ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

# Latest RPO file (the CNPG drill writes one at baseline
# and final, same date); empty when the CNPG arm has not
# run yet, in which case the RPO is "not measured".
latest_rpo() {
  ls -t "$ROOT"/evidence/rpo-*.json 2>/dev/null | head -1 || true
}

write_comparison() {
  local cnpg="$ROOT/evidence/cnpg-failover.json"
  local single="$ROOT/evidence/node-failure-drill.json"
  local guard="$ROOT/evidence/guard-live.json"
  local rpo
  rpo=$(latest_rpo)
  [ -f "$cnpg" ] || cnpg=""
  [ -f "$single" ] || single=""
  [ -f "$guard" ] || guard=""
  python3 "$ROOT/scripts/drills/ha_compare.py" \
    --cnpg "$cnpg" --single "$single" --guard "$guard" --rpo "$rpo" \
    --scope "$SCOPE" --evidence "$EVIDENCE"
}
trap write_comparison EXIT

if [ "$OFFLINE" = "true" ]; then
  echo "== offline: building the comparison from evidence/ =="
  # The EXIT trap writes it; nothing to run.
  exit 0
fi

echo "== arm (a): CNPG HA failover =="
if bash "$ROOT/scripts/drills/cnpg_failover_ci.sh"; then
  echo "arm (a): CNPG drill done"
else
  echo "arm (a): CNPG drill FAILED — recorded, continuing to arm (b)" >&2
fi

echo "== arm (b): single replica, manual out-of-service taint =="
if bash "$ROOT/scripts/drills/node_failure_ci.sh"; then
  echo "arm (b): node-failure drill done"
else
  echo "arm (b): node-failure drill FAILED — recorded, continuing" >&2
fi

if [ "$WITH_GUARD" = "true" ]; then
  echo "== arm (c): single replica, the guard applies the taint =="
  if bash "$ROOT/scripts/drills/guard_live_ci.sh"; then
    echo "arm (c): guard-live drill done"
  else
    echo "arm (c): guard-live drill FAILED — recorded" >&2
  fi
else
  echo "== arm (c): guard arm skipped (no --with-guard) =="
  if [ -f "$ROOT/evidence/guard-live.json" ]; then
    echo "arm (c): using existing evidence/guard-live.json"
  else
    echo "arm (c): no evidence/guard-live.json — recorded as not measured"
    echo "arm (c): dispatch the guard-live drill, then re-run this with --offline"
  fi
fi

# Evidence is written by the EXIT trap.
