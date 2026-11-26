# CNPG vs single replica: the measured comparison

The design comparison is docs/CNPG_COMPARISON.md (the two
architectures, the runbook, the expected shape). This doc
is the measured version: the same kill, the same row, the
same cluster, timed three ways, with the RPO alongside.
The comparison is a pure function of the drill evidence
(`scripts/drills/ha_compare.py`) — it runs no cluster and
invents no numbers.

## The three arms

| Arm | Drill | What is timed |
|---|---|---|
| CNPG HA | `scripts/drills/cnpg_failover_ci.sh` (3 trials) | Kill the node running the primary, to new-primary Ready and to serving the row, median of 3 |
| Single replica, manual taint | `scripts/drills/node_failure_ci.sh`, case 3 | Kill the node, apply the out-of-service taint by hand, to pod Ready and to serving the row |
| Single replica, guard | `scripts/drills/guard_live_ci.sh` (3 trials) | Kill the node, the guard applies the taint, to serving, median of 3; plus 3 refusal trials on a live node |

The RPO alongside is `evidence/rpo-<date>.json`
(`scripts/drills/rpo_measure.py`): the failover RPO
(standby replay lag) and the archive RPO (WAL not yet
archived; not configured on kind). The single replica's
RPO is 0 if the volume survives — the data is on the
disk, not in the pod — which is why the comparison also
notes that volume/AZ loss is a different failure (the DR
runbook covers region loss; the FIS game day covers AZ
loss on EKS).

## How to run it

CI (kind + NFS): dispatch
`.github/workflows/ha-comparison-drill.yml` from the
Actions tab. It runs arms (a) and (b) (~30-40 minutes)
and writes `evidence/ha-comparison-<date>.json` plus the
underlying arm evidence as artifacts. The guard arm is
off by default: the comparison reads
`evidence/guard-live.json` if a previous guard-live
dispatch wrote it, and records the arm as "not measured"
otherwise. To measure the guard arm, either dispatch
with `with_guard: true` (adds ~40-45 minutes), or
dispatch the guard-live drill first and re-run this
workflow — or re-run the harness with `--offline` after
a guard-live dispatch, which rebuilds the comparison
from the evidence already in the repo without running
any drill.

EKS: there is no separate EKS comparison workflow. The
one-day EKS run (`scripts/eks/run_eks_day.sh`) already
produces `evidence/cnpg-failover.json` and
`evidence/guard-live.json` (EKS-scoped, EBS); feed those
plus the EKS node-failure evidence to
`scripts/drills/ha_compare.py` with `--scope "EKS + EBS"`
to build the same table for EKS.

## What the comparison does not claim

- No expected result: which arm is fastest is genuinely
  unmeasured until the workflow runs. The guard arm is
  expected to be slowest (its 180s threshold plus the
  2-minute cadence dominate) — that is the point, the
  guard's value is automation plus triple confirmation,
  not speed.
- The single-replica number is one trial (the taint
  case), not a median of 3; the CNPG and guard numbers
  are medians of 3. The evidence records the trial
  counts, so the asymmetry is visible.
- The RPO is the baseline standby lag, not the lag at
  the kill: a write load during the kill would be a
  harder test, and is not in this comparison (the same
  caveat is in docs/CNPG_COMPARISON.md).

## Status: built, unmeasured

The harness (`scripts/drills/cnpg_compare_ci.sh`), the
comparison module (`scripts/drills/ha_compare.py`), the
workflow, and the unit tests (`python/tests/test_ha_compare.py`,
9 tests) are built; the harness's `--offline` mode was
verified in the VM against sample evidence (no kind
there). No comparison number exists yet: the workflow
needs a push and a dispatch. No number is quoted until
a run has written `evidence/ha-comparison-<date>.json`.
