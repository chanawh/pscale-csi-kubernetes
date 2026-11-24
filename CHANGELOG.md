# Changelog

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
