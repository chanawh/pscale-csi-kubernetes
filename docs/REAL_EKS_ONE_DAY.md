# One real EKS run, for a day

The kind version is the $0 version that gets you the
interview. One real EKS run is what turns "lab project"
into "ran on EKS": a real managed control plane, real
IAM, real EBS/EFS CSI drivers, and a measured pod
recovery time. Do it once, for a day, then destroy it.

This run does not need OneFS. EKS proves the AWS CSI
drivers (EBS block, EFS file); kind proves PowerScale
CSI. OneFS is not reachable from a VPC without a VPN or
a public endpoint, and that limit is stated, not worked
around. See ADR-0006.

## Cost, one day, us-west-2

| Item | Cost for one day |
|---|---|
| EKS control plane, $73/month | ~$2.40 |
| 2 x t3.medium nodes, ~$60/month | ~$2.00 |
| EBS gp3 volumes (nodes + 10-20 GiB demo), $0.08/GB-month | under $0.10 |
| EFS Standard, lab data only, $0.30/GB-month | under $0.05 |
| CloudWatch logs, lab scale | under $0.05 |
| Data transfer, lab scale | under $0.01 |
| **Total** | **about $4.50-5.00 for one day** |

Left running for a month, the same cluster is ~$135/month
plus storage. Do not leave it running. Apply, demo,
destroy the same day. Costs are estimates at lab scale;
check the AWS bill the next day and record the real total
in the evidence file.

## Prerequisites

- AWS CLI configured for the account that will be billed.
- terraform (>= 1.9), kubectl, helm, envsubst (gettext).
- Verify addon and Pod Identity service account names
  against current AWS docs before applying. Terraform
  validate proves syntax, not that AWS still uses the
  same names on the day you run it.

## Steps

1. Deploy:

   ```sh
   bash scripts/eks/deploy_eks.sh
   ```

   This runs Terraform with `enable_eks=true` (cluster,
   node group, EBS/EFS CSI addons with Pod Identity
   roles, EFS filesystem, KMS secrets encryption,
   control-plane logging), points kubectl at the cluster,
   installs the snapshot controller (it is not part of
   the EBS CSI addon), applies the EKS manifests with the
   real EFS filesystem ID substituted from Terraform
   output, and installs kube-prometheus-stack.

2. Demo:

   ```sh
   bash scripts/eks/run_eks_demo.sh
   ```

   Writes the test row to Postgres on EBS, snapshots and
   restores, expands 10 to 20 GiB, then drains the
   Postgres node and prints the measured pod recovery
   time in seconds. Record that number. It replaces the
   estimated "within 5 minutes" (the Kubernetes default
   300-second toleration for unreachable nodes) with a
   measured drain recovery on a real cluster.

3. Capture evidence before destroying:

   - `kubectl -n csi-demo get pvc,po` output
   - the demo script output, including the recovery time
   - a Grafana screenshot of node/PVC metrics during the
     drain, if the stack came up clean
   - `terraform output` (cluster endpoint, EFS ID)
   - Save under `evidence/` with the date. Evidence beats
     claims.

4. Destroy, same day:

   ```sh
   bash scripts/eks/destroy_eks.sh
   ```

   Deletes the demo namespace first so the CSI drivers
   release EBS volumes and EFS access points, uninstalls
   observability, then `terraform destroy`, then checks
   for orphaned EBS volumes and EFS filesystems. Skipping
   the PVC step can orphan EBS volumes that keep billing.

## After the run

Update the resume bullet: replace "in a $0 lab (kind +
Dell PowerScale CSI driver 2.18.1 + OneFS Simulator)"
with the measured version, for example "on EKS (one-day
lab run, destroyed same day; pod recovery measured at
N seconds after node drain)". Keep the Simulator honest
for the PowerScale half. The point is that the same
workload ran against a real EKS API with AWS CSI
drivers, not just kind, and the recovery number is
measured, not estimated.
