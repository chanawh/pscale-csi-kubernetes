# Cost model (list prices, no real spend)

No real spend exists for any of this yet: nothing in the
ceiling work has been applied to a real AWS account. Every
number below is an AWS list price as of November 2026, so a
run's actual bill can be checked against it. Verify prices
on the AWS pricing pages before a run; they change.

## EKS one-day run (docs/REAL_EKS_ONE_DAY.md)

| Item | List price | One-day cost |
|---|---|---|
| EKS cluster | $0.10/hr | $2.40 |
| 2x t3.medium nodes (us-west-2 on-demand) | $0.0416/hr each | ~$2.00 |
| EBS gp3 10 GiB (Postgres) | $0.08/GB-month | ~$0.03 |
| EBS gp3 10 GiB (EFS test volume, if used) | $0.08/GB-month | ~$0.03 |
| EFS (10 GiB, Standard) | $0.30/GB-month | ~$0.10 |
| EBS snapshots (10 GiB) | $0.05/GB-month | ~$0.02 |
| **Total, one day** | | **~$4.50** |

The $4.50 figure in the README is this table rounded. The
cluster is the expensive part, not the storage. Destroy the
same day or the cluster keeps billing $2.40/day.

## FIS AZ game day (docs/FIS_AZ_GAMEDAY.md)

FIS is $0.10 per action-minute (single account; $0.12 in
GovCloud), plus $5 per experiment report if requested.
One action running 10 minutes is ~$1.00. The game day runs
on top of the EKS one-day run, so the cluster cost above
applies; FIS itself is the cheap part.

## Cross-region DR (docs/DR_REGION.md)

| Item | List price |
|---|---|
| EBS snapshot copy, region A to B | $0.01/GB transferred to US East, $0.02/GB to other regions, plus $0.05/GB-month storage in region B |
| Restored volume, 10 GiB gp3 | $0.08/GB-month, prorated (~$0.03/day) |
| Second EKS cluster (if kept running) | $0.10/hr ($2.40/day) |

A DR rehearsal on a 10 GiB volume is about $0.20 of transfer plus ~$0.50/month of snapshot storage in region B, plus the second cluster if it is running during the rehearsal. Subsequent copies bill only changed blocks against the most recent completed copy; the first copy into a region bills the full size.

## Guard (docs/GUARD_DESIGN.md)

The guard is a CronJob running every 2 minutes in-cluster.
It costs nothing measurable: a few seconds of CPU per run
on the existing nodes, no extra infrastructure. The AWS
checker path makes one `describe-instances` call per
unreachable node per run; EC2 describe calls are free.

## CloudNativePG comparison (docs/CNPG_COMPARISON.md)

2 replicas instead of 1: a second 10 GiB EBS volume
(~$0.03/day) and a second pod on the existing nodes. The
operator itself is free (open source). The kind + NFS run
is $0.

## What would change the numbers

- Bigger volumes: storage is per-GB-month, so a 100 GiB
  Postgres volume is ~$0.27/day, not ~$0.03.
- Longer runs: the cluster is $2.40/day, so a week-long
  EKS run is ~$17 before storage.
- The 1 TB scale question from the migration project does
  not apply here: this repo's volumes are 10 GiB by design.
