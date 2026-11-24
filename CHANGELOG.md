# Changelog

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
