# Changelog

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
