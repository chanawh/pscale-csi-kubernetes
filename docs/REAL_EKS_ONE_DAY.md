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

## Primary path: one command

```sh
bash scripts/eks/run_eks_day.sh
```

The driver runs the whole day in order: Terraform apply
(EKS + EFS + guard role + Pod Identity agent, then the FIS
module), deploy + demo (row, snapshot, expand, timed node
drain), guard live timing, FIS AZ game day, cross-region
DR restore, CNPG failover, then destroy. Each step reuses
the existing script for that step; the driver only
orchestrates. It stops on the first failure, prints a
summary of what ran and what did not, and still destroys
(cost protection) unless `--no-destroy` is given. It never
touches kind — this is the real-AWS path only.

```sh
bash scripts/eks/run_eks_day.sh --dry-run      # print the plan, run nothing
bash scripts/eks/run_eks_day.sh --skip-fis --skip-dr   # partial run
```

Flags: `--no-destroy` (debugging only; the cluster keeps
billing), `--skip-fis`, `--skip-dr`, `--skip-cnpg`,
`--skip-guard`, `--dry-run`, `--help`.

Environment (in addition to `AWS_REGION` and
`CLUSTER_NAME`, defaults us-west-2 and pscale-csi):

- `FIS_CANARY_ALARM` — required unless `--skip-fis`: the
  name of an existing CloudWatch alarm used as the FIS
  stop condition. The project creates no alarm of its own.
- `FIS_TEST_DURATION_MINUTES` — default 2.
- `DR_REGION_B`, `DR_RESTORE_AZ`, `DR_KUBE_CONTEXT` — all
  required unless `--skip-dr`. Region B's cluster must
  already exist.
- `EKS_NODE_DESIRED_SIZE` — default 2. See the AZ note
  below.

AZ note: the Postgres EBS volume's AZ must have a second
Ready node, or the pod cannot reschedule to another node
(EBS is AZ-bound) and the drain demo and the guard trials
cannot reach Ready. The driver checks this after deploy
and fails fast with the fix instead of timing out 600s
into the demo: re-run with `EKS_NODE_DESIRED_SIZE=3`
(about $1.00 more for the day). The FIS game day is what
tests AZ loss; the drain and guard drills need a same-AZ
survivor.

## Manual steps (fallback)

The driver above runs all of these in order. Use the
manual steps only to debug or re-run a single step.

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

## Ceiling measurements on EKS (v1.2.0)

The four ceiling items all ride on this same cluster.
Do them after the demo above, the same day or a second
day, then destroy with step 4. None of them has run
anywhere yet; each has its own doc and evidence file.

1. **Guard live timing.** The guard is the node-down
   automation (`docs/GUARD_DESIGN.md`, `guard/node_guard.py`).
   Deploy it, then stop a worker instance and let the
   guard recover the pod unattended. The driver runs
   `scripts/eks/guard_live_eks.sh` (3 trials, the CronJob
   itself taints, evidence `evidence/guard-live.json`).
   Manually:

   ```sh
   kubectl apply -f k8s/guard/   # RBAC, script ConfigMap, CronJob (every 2 min)
   aws ec2 stop-instances --instance-ids <worker-instance-id>
   ```

   The guard taints only when all three hold: the node
   unreachable for 180s from `lastTransitionTime`, the
   EC2 API confirming the instance stopped or terminated,
   and no `csi-guard/maintenance: "true"` annotation.
   Its audit log is one JSON object per line on the
   CronJob pod's stdout. Record: time from instance stop
   to the `taint` audit line to pod Ready to serving
   queries. Save the audit lines plus those times as
   `evidence/guard-live.json`. If the guard refuses, the
   refusal reason in the audit log is the result — a
   refused taint is a safe outcome, not a failed run.
   No refusal trials on EKS (no docker-pause equivalent);
   those are covered by the kind drill.
   The CronJob needs the AWS CLI and the Pod Identity
   role to call EC2: the CronJob installs awscli at start
   (`k8s/guard/cronjob.yaml`) and Terraform provides the
   role (`terraform/guard.tf`, `ec2:DescribeInstances`
   only). Without either, the checker returns "unknown"
   and the guard refuses every time.

2. **FIS Availability Zone game day.**
   `docs/FIS_AZ_GAMEDAY.md` is the runbook (the scenario
   name is verified there: FIS calling the SSM document
   `AWSResilienceHub-SimulateAzOutageInAsgTest_2020-07-23`
   against the node-group ASG). Apply the module first
   (`terraform/fis/`, same account and region), then
   follow the doc. The driver runs
   `scripts/eks/fis_az_gameday.sh` (the driver applies
   the module; the script starts the experiment and
   measures it). Evidence:
   `evidence/dr-az-gameday.json`. FIS bills
   $0.10/action-minute. The game day needs a CloudWatch
   alarm as its stop condition (`FIS_CANARY_ALARM`); the
   project creates no alarm of its own.

3. **Cross-region DR restore.** `docs/DR_REGION.md`
   plus `bash scripts/eks/dr_region_restore.sh` (snapshot
   copy to region B, restore, verify the row). The driver
   derives the volume id and passes `REGION_B`,
   `RESTORE_AZ`, and `KUBE_CONTEXT` through. Region B's
   cluster must already exist. Evidence:
   `evidence/dr-region.json` with measured RPO/RTO.

4. **CloudNativePG failover.** `docs/CNPG_COMPARISON.md`
   (install the operator, then `k8s/cnpg/cluster.yaml`
   with the storage class swapped to `ebs-gp3`, kill a
   node, time the failover against the
   StatefulSet + guard number from item 1). The driver
   runs `scripts/eks/cnpg_failover_eks.sh` (3 trials,
   terminate the instance, ASG replaces it, evidence
   `evidence/cnpg-failover.json`, same schema as the
   kind drill).

Destroy with `bash scripts/eks/destroy_eks.sh` when all
four are done — it deletes the demo namespace first,
which also removes the guard.
