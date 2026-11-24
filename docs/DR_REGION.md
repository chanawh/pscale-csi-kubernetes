# Cross-region DR (EKS)

Restore the Postgres volume in a second region from an EBS
snapshot copy, and measure RPO and RTO. The script is
`scripts/eks/dr_region_restore.sh`. It has never been run:
there is no second cluster and no AWS account in this
environment.

## What RPO and RTO mean here

- **RPO** is the age of the snapshot at restore time: now
  minus the snapshot's StartTime. The restore cannot contain
  data newer than the snapshot, so the RPO is however old
  the latest snapshot is. Take snapshots on a schedule and
  the RPO is the schedule interval plus copy time; take them
  by hand before a game day and the RPO is minutes.
- **RTO** is restore start to the row reading back in region
  B: snapshot copy, volume create, static PV/PVC bind,
  Postgres start, test job. The script times it with
  `date +%s` and writes both numbers to
  `evidence/dr-region.json`.

## The restore, step by step

1. Find the latest snapshot of the Postgres EBS volume in
   region A (`describe-snapshots`, sorted by StartTime).
2. Copy it to region B (`copy-snapshot`, wait for completed).
   The copy is the long pole: snapshot copy time grows with
   the amount of changed data, not the volume size.
3. Create a volume from the copy in one AZ of region B.
4. Bind it statically: a PersistentVolume with
   `awsElasticBlockStore.volumeID` pointing at the restored
   volume and a `claimRef` to `postgres-data-ebs`, plus a
   matching PVC with `volumeName`. No dynamic provisioning
   is involved — the volume already exists.
5. Deploy Postgres in region B (`k8s/eks/postgres-statefulset-ebs.yaml`,
   which also creates the headless `postgres` Service) and
   run the test job (`k8s/test-job.yaml`). The row
   `csi-powerscale-proof` must read back. A missing or
   changed row is data loss, not a slow restore.

## Prerequisites

- A second EKS cluster in region B, with kubectl access
  (`KUBE_CONTEXT`). It needs no EBS CSI driver for this
  restore: the PV is static and the in-tree
  `awsElasticBlockStore` volume type is used. (The in-tree
  type is deprecated in favor of the EBS CSI driver; the
  CSI equivalent is a static PV with `csi.volumeHandle`.
  The script uses the in-tree type because it needs no
  driver installed in the DR cluster. That tradeoff is
  recorded here so it is a decision, not an accident.)
- The `postgres-secret` Secret (`k8s/postgres-secret.yaml`)
  applied in region B. Same lab-only password as the main
  cluster.
- IAM permission for `ec2:CopySnapshot`, `ec2:CreateVolume`,
  `ec2:DescribeSnapshots` in both regions.

## What this does not cover

- **The standby region's cluster.** This restores the data,
  not the cluster. If region A is gone, region B's cluster
  must already exist (or be built from Terraform, which takes
  ~15 minutes on top of the RTO measured here). A full
  region-loss game day includes the cluster build; this
  script does not.
- **Continuous replication.** Snapshots are point-in-time.
  Anything written after the latest snapshot is lost. For a
  smaller RPO the answer is continuous replication (EBS
  snapshot schedules, or a CNPG standby in region B — see
  docs/CNPG_COMPARISON.md), not faster copies.
- **EFS / PowerScale.** The DR path here is EBS snapshots.
  EFS has its own replication (EFS replication to a second
  region); PowerScale has SyncIQ to a second cluster. Neither
  is scripted here.
