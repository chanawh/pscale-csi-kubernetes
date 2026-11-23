# Interview guide: how to talk about this project

## The STAR bullet (use this on the resume, verbatim)

> Built PowerScale CSI storage for Kubernetes in a $0 lab
> (kind + Dell PowerScale CSI driver 2.18.1 + OneFS Simulator):
> ran Postgres on a PowerScale PVC via Dell's CSI driver, with
> StorageClasses per access zone, and proved snapshot/restore,
> clone, volume expansion from 10 to 20 GiB, and node-failure
> rescheduling with data intact; Terraform for EKS gated for
> the real-AWS path.

After the one-day EKS run, the upgraded bullet (use only
once measured and evidenced):

> Deployed stateful Kubernetes workloads on CSI storage
> across PowerScale (kind lab) and EKS (Terraform-built
> cluster, EBS gp3 + EFS CSI addons with Pod Identity):
> snapshot/restore, online expansion 10 to 20 GiB, and
> node-drain rescheduling with data intact, pod recovery
> measured at N seconds; Prometheus/Grafana observability
> on EKS.

Do not change "lab" to "production". The PowerScale
cluster is kind, the storage is a Simulator, and the EKS
Terraform is validated only until the one-day run is
applied, measured, and evidenced. Saying otherwise loses
the role in a technical interview.

## The 30-second pitch

"Kubernetes pods lose their data when they die, so I gave
them a real disk: Dell's PowerScale CSI driver, talking to
the OneFS node I already run. Postgres runs on a PowerScale
PVC, and I proved it with four drills, snapshot and restore,
clone, expand, and killing a worker node to show the volume
follows the pod. It runs for free on kind, and the same
workload runs on EKS with AWS's EBS and EFS CSI drivers,
where the node drain is timed so the recovery number is
measured."

## Ten questions you will be asked, and the answer

1. Did you write the CSI driver?
   No. Dell wrote it. I installed it, configured it, and
   operated it. Writing a CSI driver is months of gRPC
   work and is not the job. Operating one is.

2. What is CSI, in one sentence?
   The standard API Kubernetes uses to ask an outside
   storage system for a disk, so a pod can keep its data
   after it dies or moves nodes.

3. What are the controller and node plugins?
   The controller is central and talks to OneFS to create
   directories, NFS exports, and quotas. The node plugin
   runs on every worker and mounts the NFS export for
   the pod on that node.

4. Why ReadWriteMany?
   NFS lets many pods mount the same volume at once.
   EBS is ReadWriteOnce, one pod at a time. Postgres
   here is one replica, but the mode is what NFS gives you.

5. How does a snapshot work?
   A VolumeSnapshot asks the driver to make a point-in-
   time copy on OneFS. A new PVC from that snapshot
   restores the data. The snapshot class IsiPath must
   match the StorageClass IsiPath, or the driver cannot
   find the source.

6. How does expansion work?
   Edit the PVC from 10 to 20 GiB. The resizer sidecar
   calls the controller, the controller grows the
   SmartQuota, and the pod sees a bigger disk without
   being recreated. It only works because
   allowVolumeExpansion is true on the StorageClass.

7. What happens when a node dies?
   The pod is rescheduled on the other worker, the node
   plugin on that worker mounts the same NFS export,
   and Postgres starts with the same data. The drill
   proves it by stopping the kind node with docker stop.

8. Why is SmartQuota on?
   By default the driver does not enforce size. Without
   a quota, a volume can grow past its PVC size and
   fill OneFS. Quotas are the enforcement.

9. Why NFS only?
   That is what Dell's PowerScale driver supports.
   There is no SMB or block mode. If a workload needs
   block storage, PowerScale CSI is the wrong driver.

10. What would you do differently on EKS?
    Two replicas for the controller, a real TLS cert
    instead of skipCertificateValidation, a dedicated
    service account for the driver instead of root,
    and the EKS Terraform in terraform/eks.tf, which
    is gated off in the lab. Then destroy the cluster
    the same day, EKS is ~$135/month left running.

11. EBS vs EFS vs PowerScale, when each?
    EBS is block, ReadWriteOnce, AZ-bound: right for a
    single-writer database, wrong for shared files.
    EFS is file, ReadWriteMany, multi-AZ, throughput
    network-bound: right for shared uploads and caches.
    PowerScale CSI is NFS ReadWriteMany on enterprise
    storage you already own, with SmartQuotas and
    snapshots: right when the data must stay on OneFS.
    Same PVC API, three different failure and cost
    profiles. That comparison is the project.

12. What is EKS Pod Identity, and why not IRSA?
    Pod Identity binds an IAM role to one namespace +
    service account through the EKS API, so each CSI
    controller gets least-privilege credentials without
    maintaining an OIDC provider thumbprint. IRSA does
    the same job through IAM roles for service accounts
    and an OIDC provider; Pod Identity is the newer,
    simpler path for EKS addons. Either beats giving
    the node role storage permissions.

13. Your pod recovery was "within 5 minutes". Explain.
    That estimate came from the kind drill's
    `kubectl wait --timeout=300s` and the Kubernetes
    default: an unreachable node is marked NotReady
    after ~40s, and pods carry a default 300s
    toleration before eviction. On EKS the drill uses
    `kubectl drain`, which is graceful, and times
    drain-to-Ready with `date +%s`, so the number I
    quote after the EKS run is measured, not the
    default toleration restated. If I needed faster
    failover I would shorten tolerationSeconds and
    accept the flapping risk that comes with it.

14. How does observability work on EKS here?
    kube-prometheus-stack: Prometheus scrapes node
    exporter, kube-state-metrics, and CSI controller
    metrics. The dashboard and alerts are built as code
    in monitoring/: an 8-panel Grafana dashboard (PVC
    phase, requested vs used bytes, Postgres restarts,
    pod readiness during the drain, node CPU/memory,
    CSI controller pods, snapshot readiness) and a
    PrometheusRule with 5 alerts (PVC pending, PVC over
    85% full, Postgres not ready, CSI controller down,
    snapshot not ready), validated by tests, loaded on
    the EKS run. EKS control-plane logs go to
    CloudWatch. Retention is 24h because it is a
    one-day lab, not a production monitoring platform.

## What not to say

- Do not say you wrote a CSI driver.
- Do not say this ran on EKS or in production.
- Do not say kind ran live here. It did not, this VM
  has no Docker. kind runs in CI and on your machine.
- Do not hide the Simulator. Lead with it: "kind +
  OneFS Simulator, $0, same manifests as EKS."
