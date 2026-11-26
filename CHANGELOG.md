# Changelog

## v1.2.4, 2026-11-26

The two unbuilt pieces of the optimal design are built
(written, not run — kind cannot run in the build VM,
and the S3 part needs real AWS):

- **WAL archive to S3 (RPO).** `terraform/cnpg_wal.tf`
  (S3 bucket + KMS key + IAM role for CNPG via Pod
  Identity, gated `enable_eks` off by default),
  `k8s/cnpg/objectstore.yaml` (Barman Cloud plugin
  ObjectStore, `s3Credentials.inheritFromIAMRole: true`)
  + `k8s/cnpg/backup.yaml` (base backup, method plugin),
  `scripts/drills/rpo_measure.py` (stdlib: standby
  replay lag + archive lag, in seconds and WAL bytes,
  to `evidence/rpo-<date>.json`; "not measured" with a
  reason when the cluster is down or the archive is not
  configured), `docs/WAL_ARCHIVE.md`. The EKS CNPG
  script installs cert-manager + the Barman plugin,
  applies the ObjectStore, enables archiving, takes a
  base backup, and measures the RPO at baseline and
  final. The kind CNPG drill measures the failover RPO
  only (no archive on kind). Tests: 17 RPO + 6 WAL
  manifest tests.
- **CNPG-vs-single-replica comparison.** `scripts/drills/ha_compare.py`
  (stdlib: builds the table from the drill evidence —
  CNPG median, single-replica manual-taint, guard
  median + refusals, RPO — and names the fastest arm;
  a missing arm is "not measured", never invented),
  `scripts/drills/cnpg_compare_ci.sh` (runs the CNPG
  drill, the node-failure drill, and — with `--with-guard`
  only — the guard-live drill, then writes
  `evidence/ha-comparison-<date>.json` on EXIT; `--offline`
  rebuilds the table from the evidence already in
  `evidence/`), `.github/workflows/ha-comparison-drill.yml`
  (manual dispatch, `with_guard` input, default false),
  `docs/HA_COMPARISON.md`, 9 unit tests in
  `python/tests/test_ha_compare.py`. Verified in the VM
  by an `--offline` dry-run against sample evidence
  (full table) and against the real node-failure
  evidence alone (CNPG + guard + RPO recorded as not
  measured); the sample fixtures were deleted, nothing
  invented was committed. No comparison number exists
  yet — the workflow needs a push and a dispatch.

Also in this release (local since v1.2.3, not yet
pushed): the EKS one-day driver (`scripts/eks/run_eks_day.sh`
+ per-item scripts, commit cb3da1a; fixes the missing Pod
Identity agent addon, the guard CronJob's missing AWS
CLI + IAM role, deploy_eks.sh not passing cluster_name,
and the EFS leftover check), the CNPG setup-row retry
(commit bbec4a0 — the CNPG drill failed in CI, run
45529763004; the retry is the most likely fix, not a
confirmed root cause), and the pg_isready readinessProbe
(commit 54a7334 — the guard-live drill failed in CI, run
45529757950; the probe fixes the post-taint race the
step timings point to, also not log-confirmed). Both
re-dispatches need the push first. Tests 74/74.

## v1.2.3, 2026-11-24

PowerScale-path drill upgraded to the three cases.
`scripts/drills/node_failure.sh` was a single-case script
(hard stop + taint only); it now runs the same three cases
as the CI drill — drain, hard-stop stall (240s, with
deletionTimestamp/tolerations/node-taints recorded), hard
stop + out-of-service taint — on the PowerScale volume,
with the EXIT-trap evidence writer (partial evidence on
failure) and a safety check that refuses to run unless
the PVC is on the `powerscale` StorageClass, so the
PowerScale evidence can never be measured on NFS by
mistake. Evidence to `evidence/node-failure-powerscale.json`
(scope, kind/kubernetes versions, storage class,
provisioner csi-isilon.dellemc.com, volume handle, OneFS
endpoint, the three cases). `docs/POWERSCALE_DRILL_RUNBOOK.md`
updated to match. Written, not run: it runs on Andrew's
machine only (kind + OneFS Simulator), not in CI or the
build VM. Tests 40/40; the script is bash -n clean and
its evidence writer was tested in the VM with sample
values.

## v1.2.2, 2026-11-24

CNPG failover drill, written not run. `scripts/drills/cnpg_failover_ci.sh`
+ `.github/workflows/cnpg-failover-drill.yml` (manual dispatch):
3 failover trials on kind + NFS (docker kill the node
running the CNPG primary, time kill to new-primary
Ready and to serving the row, restart the node, require
the cluster back to Ready with the row intact; a trial
that does not heal is recorded failed, not hidden).
Evidence to `evidence/cnpg-failover.json` (median
serving, per-trial new primary, row intact). No
expected time is stated: CNPG promotion time on kind
is genuinely unmeasured. Needs a push and a manual
dispatch to run. Also fixes a latent bug the drill
found: the ceiling-written cluster.yaml pointed its
bootstrap secret at postgres-secret, whose keys are
POSTGRES_USER and friends — CNPG requires a
kubernetes.io/basic-auth secret with username/password
keys, username matching the owner, so the cluster
would never have created. New `k8s/cnpg/secret.yaml`
is that secret, and the runbook's psql steps now
carry PGPASSWORD and --restart=Never. Tests 40/40;
the new script is bash -n clean and its evidence
writer was tested in the VM with sample values. The
live paths cannot run here (no container networking).

## v1.2.1, 2026-11-24

Guard live drill, written not run. `scripts/drills/guard_live_ci.sh`
+ `.github/workflows/guard-live-drill.yml` (manual dispatch):
3 live-guard timing trials (guard applies the taint on a
2-minute cadence matching the production CronJob, offsets
0/40/80s for phase spread) and 3 refusal trials (docker
pause: node Unknown, container alive, guard must refuse).
Evidence to `evidence/guard-live.json` (median serving,
refusals N of 3, guard config). Expected as built:
kill to serving ~240-360s, slower than the manual 198s
(180s threshold + up to 120s CronJob wait); the guard's
value as built is automation plus triple confirmation,
not speed. Needs a push and a manual dispatch to run.
Also: `docs/REAL_EKS_ONE_DAY.md` gained the ceiling
measurements section (guard live timing, FIS AZ game day,
cross-region DR, CNPG failover). Tests 40/40; the new
script is bash -n clean and its evidence writer + audit
parsing were tested in the VM with sample values. The
live paths cannot run here (no container networking).

## v1.2.0, 2026-11-24

Ceiling version. What is real, and what is only written:

**Real (tested here).** The node-down guard
(`guard/node_guard.py`, ~350 lines stdlib Python): applies
the out-of-service taint only when the node has been
unreachable 180s AND a second source confirms the instance
is down (docker for kind, EC2 API for EKS) AND no
maintenance annotation is set; dry-run, JSON-lines audit,
auto-removal of its own taint, never touches a human
taint. 15 unit tests (fake client/checker) + a live run
against fake kubectl/docker that caught a real bug
(KindChecker read node['name']). CronJob + RBAC +
generated ConfigMap in `k8s/guard/`; false-positive chaos
test wired into the drill workflow. SLOs: 2 multi-window
burn-rate alerts + 2 dashboard panels (10 panels, 7
alerts). IaC scanning in CI (tflint core rules + checkov,
58 passed / 0 failed; 3 checks skipped with reasons —
KMS key policies require Resource "*"). Checkov triage
fixed 3 real findings (FIS log group KMS + 365d retention,
explicit policies on both KMS keys). FIS module
(`terraform/fis/`, SSM Resilience Hub document, DIY JSON
alternative) validates clean. Tests 40/40.

**Written, unrun.** Guard live taint timing (needs a CI
drill run where the guard applies the taint); CNPG
failover timing (runbook + 2-replica manifest, needs a
cluster); FIS AZ game day and cross-region DR restore
(runbooks + scripts, need EKS). No number from any of
these appears in the README — the reviewer-path table
lists them as pending. EKS one-day run still pending.

## v1.1.8, 2026-11-24

Answer the open stall question. Run 45336965561
showed the pod Running/NotReady for 240s with no
replacement — not Terminating, as the docs said.
Phase is kubelet-reported, so a dead kubelet leaves
it stale; whether eviction started is decided by
the pod's deletionTimestamp. Case 2 now records
deletionTimestamp, tolerations, and node taints in
the log and in `evidence/node-failure-drill.json`,
so the next run settles whether the 30s
tolerations fired at ~70s. No behavior change.
Tests still 20/20.

## v1.1.7, 2026-11-24

PowerScale-path drill, ready to run. The CI numbers are
kind + NFS; the PowerScale measurement needs a live kind
cluster against the OneFS Simulator, which only exists
on Andrew's machine. Two changes make that run
one-command: `scripts/drills/node_failure.sh` now writes
`evidence/node-failure-powerscale.json` (Ready/serving
seconds, nodes, row verified), and its NotReady wait
accepts `Unknown` as well as `False` (the CI lesson from
run 45339015253). New `docs/POWERSCALE_DRILL_RUNBOOK.md`
is the ordered machine runbook (simulator → OneFS setup
→ kind → driver → full demo → evidence → teardown),
cross-referencing the existing docs instead of
reprinting them. Tests still 20/20.

## v1.1.6, 2026-11-24

Measured node-failure numbers, at last. Run
45339015253 (kind v0.31.0) completed all three
cases: drain Ready 2s / serving 5s (earlier run:
6s / 10s); hard stop with no intervention stalled
as predicted (pod Running, not Ready, after 240s)
and recovered in place on node restart, row
intact; hard stop + out-of-service taint Ready
195s / serving 198s. Most of the 198s was the node
sitting in Unknown — after a hard kill a node goes
Unknown, not False, so the wait burned 180s before
the container-state fallback applied the taint; the
taint itself recovered the pod in ~15s. Evidence
committed at `evidence/node-failure-drill.json`.
`wait_notready` now accepts Unknown as well as
False. The run's overall conclusion was failure
only because the post-job kind teardown could not
remove a node container — drill and evidence
upload both succeeded. Tests still 20/20.

## v1.1.5, 2026-11-24

Second drill run (45336965561) got further, then
died in case 3: the node had not reported NotReady
90s after the kill, and `wait_notready` returning 1
killed the script under `set -e` — silently, and
before any evidence was written. Case 1 measured
again (Ready 2s, serving 5s) and case 2 confirmed
the stall (pod Running/Ready False after 240s,
recovered in place after the node restart, row
intact). Fixes: `wait_notready` now logs every poll
and waits 180s; case 3 falls back to the container
state (`docker inspect`) when the NotReady flag
lags, and fails loudly only if the container is
still running. Evidence is now written by an EXIT
trap, so a mid-drill failure still leaves a partial
artifact with the measured cases and the failing
command. Tests still 20/20.

## v1.1.4, 2026-11-24

First drill run, first fix. Run 45333538587 (24 Nov
2026) measured case 1 (drain): Ready in 6s, serving
in 10s, pod moved to the other worker, row intact.
Cases 2–3 never ran: `docker stop` on the kind node
container failed on the runner ("tried to kill
container, but did not receive an exit event"), so the
script died under `set -e` before writing evidence.
Both drill scripts now use `docker kill` (SIGKILL):
the daemon cannot hang on it, and a kill is the more
faithful hard failure — a power cut, not a graceful
shutdown. Docs updated to match. Tests still 20/20.

## v1.1.3, 2026-11-23

Node-failure correction. A hard stop does NOT reschedule
a StatefulSet pod on its own: the pod stays Terminating
on the dead node (at-most-one), so the old drill script,
README, and kind-config comment all overstated it. The
local drill (`scripts/drills/node_failure.sh`) now
applies the out-of-service taint after NotReady +
eviction start and times recovery from the docker stop.
New three-case CI drill (`scripts/drills/node_failure_ci.sh`,
`.github/workflows/node-failure-drill.yml`, manual run):
drain (graceful), hard stop with no intervention
(expected stall), hard stop + out-of-service taint
(timed), on kind + in-cluster NFS provisioner, results
in `evidence/node-failure-drill.json`. New
`docs/NODE_FAILURE_DRILL.md` (Terminating trap, 40s
detection + 30s toleration = eviction starts ~70s,
taint GA 1.28, force-delete split-brain risk and the
6-minute force-detach timeout, drain vs failure, EKS
equivalent with the EBS AZ note). No live cluster run
yet anywhere: no drain and no hard kill has run, on
kind or EKS. Tests still 20/20 (NFS PVC covered in
test_pvc).

## v1.1.2, 2026-11-23

Tuned node-failure drill: 30s eviction tolerations
(`node.kubernetes.io/not-ready` and `node.kubernetes.io/unreachable`,
NoExecute) on both Postgres StatefulSets (kind/PowerScale and
EKS/EBS) so the drill measures a tuned recovery instead of the
300s Kubernetes default; `scripts/drills/node_failure.sh` now
times docker-stop to pod-Ready and to serving queries. Validated
by 1 new test (20/20 pass). Live drill not yet run from this
build environment (no container networking in the VM); runs on
kind with the OneFS Simulator or on the EKS one-day run.

## v1.1.1, 2026-11-22

Monitoring as code: `monitoring/grafana/csi-storage-dashboard.json`
(8 panels: PVC phase, requested vs used bytes, Postgres
restarts, pod readiness for the drain drill, node CPU/memory,
CSI controller pods, snapshot readiness) and
`monitoring/prometheus/csi-alerts.yaml` (PrometheusRule, 5
alerts: PVC pending, PVC over 85% full, Postgres not ready,
CSI controller down, snapshot not ready). Validated by 2 new
tests (20/20 pass). Built as code, not yet applied to a live
cluster from this build environment; loads with the
observability stack on the EKS one-day run.

## v1.1.0, 2026-11-21

EKS upgrade. Terraform now builds the full real-AWS path:
EKS cluster (1.31) + managed node group, EBS/EFS CSI
addons with EKS Pod Identity least-privilege roles, EFS
filesystem (encrypted, one mount target per subnet), KMS
secrets encryption, CloudWatch control-plane logging, all
gated by `enable_eks = false`. New `k8s/eks/` manifests
(EBS gp3 + EFS StorageClasses, EBS snapshot class, EBS
Postgres workload, EFS shared claim, snapshot/restore),
kube-prometheus-stack observability values, and
`scripts/eks/` deploy/demo/destroy scripts with a timed
node-drain drill. ADR-0006 records the decision. Tests
9 -> 17, all passing; Terraform fmt/validate clean.
Not applied from the build VM (no AWS account, no
Docker): the EKS run is a one-day operator run, destroyed
same day, per `docs/REAL_EKS_ONE_DAY.md`.

## v1.0.0, 2026-11-19

Final portfolio form. System design, five ADRs, SECURITY.md,
CONTRIBUTING.md, interview guide, roadmap, CI green on the
final commit, tagged `v1.0.0`.

## Earlier

Initial build, 2026-11-18. Verified live locally, CI added,
honest limits stated up front.
