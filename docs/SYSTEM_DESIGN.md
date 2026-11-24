# System design: PowerScale CSI on Kubernetes

## 1. Problem

Kubernetes pods lose their data when they die or move
nodes. Give them a real disk, first on PowerScale and now
also on AWS, so a Postgres pod can be killed, rescheduled,
snapshotted, cloned, and expanded, and its data survives
all of it on any of the three storage systems.

## 2. Requirements

Functional:
- Dynamic provisioning: a PVC creates a volume on OneFS
  (kind), on EBS, or on EFS (EKS).
- ReadWriteMany where the storage allows it: PowerScale
  NFS and EFS give RWX; EBS block gives ReadWriteOnce.
- Snapshot and restore, clone, and in-place expansion.
- Node failure: the pod reschedules on another worker
  with the same volume reattached, timed on EKS.

Non-functional:
- Integrity over speed: quotas enforce PVC size, or a
  volume can grow past it and fill OneFS.
- Operability: one command creates the cluster, one
  installs the driver, one runs the whole demo.
- Cost: $0 on kind, about $4.50 for a one-day EKS run.
- Portability: the same workload runs on kind and on
  EKS; only the StorageClass and claim change.

## 3. Architecture

```mermaid
flowchart LR
    User[User\nPVC 10Gi, RWX]
    SC[StorageClass powerscale\ncsi-isilon.dellemc.com]
    Prov[CSI provisioner\nsidecar]
    CTRL[CSI controller\nOneFS API: mkdir,\nNFS export, quota]
    OneFS[OneFS Simulator\n/ifs/data/csi/pvc-xxx]
    Node[CSI node plugin\nDaemonSet, mount NFS]
    Pod[Postgres pod\n/var/lib/postgresql/data]
    User --> SC --> Prov --> CTRL --> OneFS
    OneFS --> Node --> Pod
    Snap[Snapshotter\nVolumeSnapshot]
    Res[Resizer\n10Gi to 20Gi]
    CTRL -. snapshot .-> Snap
    CTRL -. expand .-> Res
```

The controller is central and talks to OneFS. The node
plugin runs on every worker and mounts NFS. The sidecars
are Kubernetes-supplied: provisioner, attacher,
snapshotter, resizer, registrar, and health monitor.

On EKS the shape is the same, the backends differ: the
EBS CSI controller creates gp3 volumes through the EC2
API and the node plugin attaches and mounts them; the
EFS CSI controller creates one access point per PVC and
the node plugin mounts NFS. Each controller gets its own
IAM role through EKS Pod Identity, bound to one namespace
and service account. Terraform (`terraform/eks.tf`,
`terraform/efs.tf`) builds the cluster, node group,
addons, EFS filesystem, KMS secrets encryption, and
control-plane logging, all gated by `enable_eks = false`.
See ADR-0006.

## 4. Scale and capacity

| Dimension | Design target | Lab | What breaks first at target |
|---|---|---|---|
| Volumes | 10s of PVCs, 1 cluster | 1 Postgres PVC, 10 GiB | One driver instance per cluster, NFS export count on OneFS |
| Volume size | 10-20 GiB per PVC | 10 GiB, expanded to 20 GiB | SmartQuota per volume, OneFS capacity |
| Pods per volume | ReadWriteMany, many readers | 1 Postgres replica | NFS locking, not the driver; Postgres itself is single-writer |
| Nodes | 2 workers, so a failure has somewhere to go | kind, 2 workers; EKS, 2 x t3.medium | kind is a lab, not a production topology; EBS is AZ-bound, so a volume cannot follow a pod across AZs |
| Throughput | NFS over the host LAN, ~1 Gb/s in the lab | Local, unmeasured | Network to OneFS, not the CSI driver |

NFS is the bottleneck and the feature at once: it gives
ReadWriteMany, which block storage cannot, and it caps
throughput at the network, not at the disk. At real scale
the answer is SmartConnect for load balancing across
OneFS nodes, and a dedicated storage network, not a
faster driver.

## 5. Data model

- StorageClass: provisioner `csi-isilon.dellemc.com`,
  `AccessZone: System`, `IsiPath: /ifs/data/csi`,
  `ClusterName: nas2aws-onefs`, `allowVolumeExpansion: true`,
  `volumeBindingMode: WaitForFirstConsumer`.
- PVC: 10 GiB, ReadWriteMany, `storageClassName: powerscale`.
- PV: created by the driver, pointing at the NFS export
  for `/ifs/data/csi/pvc-xxx`.
- VolumeSnapshot: `VolumeSnapshotClass: powerscale-snapclass`,
  same `IsiPath` as the StorageClass, or the driver cannot
  find the source.
- Clone and restore are PVCs with a `dataSource`, a
  VolumeSnapshot or a PVC, not copies made by hand.
- EKS classes: `ebs-gp3` (provisioner `ebs.csi.aws.com`,
  encrypted, `WaitForFirstConsumer` so the volume lands
  in the pod's AZ) and `efs` (provisioner
  `efs.csi.aws.com`, `provisioningMode: efs-ap`, one
  access point per PVC, filesystem ID substituted from
  Terraform output at deploy time, never committed).
- EKS claims mirror the PowerScale ones at 10 GiB:
  `postgres-data-ebs` (RWO) for Postgres, `shared-data-efs`
  (RWX) for shared-file workloads. Same test row proves
  survival on every backend.

## 6. Failure modes

| Failure | Detection | Behaviour |
|---|---|---|
| Pod dies | Kubernetes reschedules it | Node plugin on the new worker mounts the same NFS export, data is still there |
| Worker node dies | kind: `docker kill`; EKS: `kubectl drain`, timed | Pod reschedules on the other worker, same volume reattached; EKS drill prints measured recovery seconds |
| Volume fills up | SmartQuota, if enabled | Writes fail at the quota, not when OneFS fills. Without quotas, nothing stops it |
| OneFS unreachable | Driver probe on start, node labels missing | Controller pods fail to probe, PVCs stay Pending, never silently mount the wrong storage |
| Snapshot class IsiPath mismatched | Snapshot stays not readyToUse | Restore PVC cannot be created; fix the class, do not force it |
| Driver secret missing | Controller crash-loops | Install script creates the secret before Helm install, or the driver has no credentials to start with |

## 7. Security

- The driver needs OneFS credentials. They live in a
  Kubernetes Secret, `isilon-creds`, created from
  `helm/isilon-creds.yaml`, which is never committed.
  The example file holds `CHANGE-ME`, not a password.
- `skipCertificateValidation: true` is lab-only, because
  the Simulator uses a self-signed cert. On a real
  cluster, set it false and provide `isilon-cert-0`.
- The Postgres password in `k8s/postgres-secret.yaml`
  is `postgres`, a lab placeholder, stated as such.
- The driver runs with the permissions it needs to
  create directories, exports, and quotas on OneFS,
  and no more. It does not need cluster-admin on
  Kubernetes beyond what the Helm chart grants.
- On EKS, each CSI controller gets a dedicated IAM role
  via Pod Identity (`AmazonEBSCSIDriverPolicy`,
  `AmazonEFSCSIDriverPolicy`), not node-wide credentials.
  EKS Secrets are envelope-encrypted with a KMS key, and
  EFS mount targets accept NFS only from the VPC CIDR.
  The default VPC is a lab shortcut, stated in SECURITY.md.

## 8. Observability

- Driver metrics: podmon exposes array status and
  metrics on port 8444, and the driver exposes a
  metrics endpoint for Prometheus scraping.
- Kubernetes events: `kubectl get events -n csi-demo`
  shows provisioning, attach, mount, snapshot, and
  expand, in order, which is the first place to look
  when a PVC stays Pending.
- The test Job writes a row, `csi-powerscale-proof`,
  and reads it back after every drill. That row is the
  proof, not a log line saying "success".
- On EKS, kube-prometheus-stack (`helm/observability-values.yaml`)
  adds Prometheus + Grafana + Alertmanager: node pressure,
  kube-state PVC/pod state, and rescheduling during the
  drain drill. Control-plane logs go to CloudWatch. The
  stack is sized for lab nodes (24h retention, small
  requests) and is not a production monitoring platform.

## 9. Cost

kind: $0. EKS, one day: about $4.50-5.00, control plane
~$2.40, 2 x t3.medium ~$2.00, EBS/EFS/CloudWatch at lab
scale under $0.25. Left running for a month: ~$135/month
plus storage. See `docs/REAL_EKS_ONE_DAY.md`. The
OneFS Simulator is free for non-production use.

## 10. Tradeoffs, and what was not chosen

- Use Dell's driver, do not write one: writing a CSI
  driver is months of gRPC work and is not the job.
  See ADR-0001.
- NFS ReadWriteMany, not block ReadWriteOnce: NFS is
  what PowerScale gives you, and RWX is the feature.
  See ADR-0002.
- kind lab, EKS gated: $0 to build and test, real
  EKS for one day to prove it. See ADR-0003.
- EKS as second runtime, AWS CSI alongside PowerScale
  CSI, Pod Identity over IRSA: proves real cloud
  Kubernetes without losing the PowerScale
  differentiator. See ADR-0006.
- Quotas on: without them, a volume can grow past
  its PVC size. See ADR-0004.
- Postgres single replica, not clustered: the point
  is the storage, not HA Postgres. See ADR-0005.

## 11. What I would do next at real scale

Two controller replicas, a real TLS cert, a dedicated
driver service account instead of root, SmartConnect
for load-balanced NFS, a dedicated storage network,
CSI replication for multi-cluster disaster recovery, a
private-subnet VPC instead of the default VPC on EKS,
and an EKS node group across AZs with topology-aware
scheduling for EBS. None of those are in the lab, and
none are claimed to be.
