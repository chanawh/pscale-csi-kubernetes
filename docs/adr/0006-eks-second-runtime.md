# ADR-0006: EKS as second runtime, AWS CSI alongside PowerScale CSI

Status: accepted (v1.1.0, 2026-11-21). Updates ADR-0003.

## Context

ADR-0003 made kind the lab path and gated EKS off: $0 to
build, same manifests on a real cluster later. That proved
PowerScale CSI, but it left the cloud half unproven.
Platform and SRE interviewers read "kind cluster" as a toy:
no VPC, no IAM, no managed control plane, no AWS CSI
drivers. The project needed a real-AWS runtime without
losing the PowerScale differentiator, and without pretending
a one-day lab run is production.

## Decision

Add EKS as a second runtime for the same project, still
gated by `enable_eks = false` by default:

- Terraform builds the EKS cluster (1.31, matching kind),
  a 2-node managed node group, KMS secrets encryption, and
  control-plane logging to CloudWatch.
- EBS CSI and EFS CSI are installed as EKS addons, each
  with its own least-privilege IAM role bound by EKS Pod
  Identity to one namespace + service account
  (`ebs-csi-controller-sa`, `efs-csi-controller-sa`).
  Pod Identity over IRSA: no OIDC thumbprint to maintain.
- An EFS filesystem (encrypted, one mount target per
  subnet, NFS 2049 from the VPC CIDR only) gives the
  AWS-native ReadWriteMany counterpart to PowerScale NFS.
- The same Postgres workload runs on three storage
  classes, so storage is the variable and the workload is
  the constant: PowerScale (RWX, kind), EBS gp3 (RWO, EKS),
  EFS (RWX, EKS).
- Observability is kube-prometheus-stack via Helm
  (`helm/observability-values.yaml`), sized for lab nodes.
  The CloudWatch observability addon is available behind
  `enable_cloudwatch_observability`, off by default.
- The EKS node-failure drill is `kubectl drain`, timed
  with `date +%s`, so pod recovery is measured on EKS
  instead of estimated from kind defaults.

## Consequences

- Good: one project now proves enterprise file storage
  (PowerScale CSI) and real cloud Kubernetes (EKS + EBS/EFS
  CSI + Pod Identity + Terraform) without a third project.
- Good: EBS vs EFS vs PowerScale is an interview-ready
  comparison: block RWO vs file RWX, AZ-bound vs multi-AZ,
  quota enforcement vs access points.
- Good: still $0 by default. EKS costs ~$4.50 for one day,
  ~$135/month left running, so the runbook destroys it the
  same day and checks for orphaned EBS volumes after.
- Bad: EKS does not replace the kind drills. OneFS is not
  reachable from a VPC without a VPN or public endpoint,
  so PowerScale CSI still proves itself on kind, and EKS
  proves the AWS CSI drivers. Both runtimes are labelled
  lab until a real run is measured and evidenced.
- Bad: more moving parts to keep honest: addon versions,
  Pod Identity associations, and the snapshot controller
  (not part of the EBS CSI addon) must be verified against
  current AWS docs at apply time, not assumed.
