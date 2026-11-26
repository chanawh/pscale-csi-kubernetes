# WAL archive to S3 (CNPG RPO)

The CNPG cluster's WAL archive is how point-in-time
recovery works, and the archive lag is the RPO. This doc
is the backup config, the RPO definition, and how to run
it. The failover comparison itself is
docs/CNPG_COMPARISON.md; the measured comparison of the
two Postgres shapes is docs/HA_COMPARISON.md.

## Why the plugin, not the in-tree config

CNPG's in-tree Barman Cloud integration
(`spec.backup.barmanObjectStore`) is deprecated since
1.26 and removed in 1.31/1.32 (the repo pins 1.30.1, so
it would still work, with a deprecation warning on every
apply). New clusters back up through the Barman Cloud
Plugin (CNPG-I): an `ObjectStore` resource holds the
bucket, credentials, compression, and retention, and the
Cluster points at it with a `plugins` entry. The plugin
(v0.15.1) adds a Barman sidecar to every instance pod;
that sidecar runs `barman-cloud-wal-archive` for every
WAL segment and `barman-cloud-backup` for base backups.
The plugin needs cert-manager (it talks to the operator
over mutual TLS) and must live in the operator's
namespace (`cnpg-system`).

## The pieces

| Piece | File | Runs where |
|---|---|---|
| ObjectStore (bucket, credentials, retention) | `k8s/cnpg/objectstore.yaml` | EKS only |
| Base backup (method: plugin) | `k8s/cnpg/backup.yaml` | EKS only |
| S3 bucket + KMS key + IAM role + Pod Identity | `terraform/cnpg_wal.tf` | EKS only (gated by `enable_eks`) |
| RPO measurement | `scripts/drills/rpo_measure.py` | kind + EKS |
| Plugin install + Cluster patch + base backup | `scripts/eks/cnpg_failover_eks.sh` | EKS only |

The checked-in `k8s/cnpg/cluster.yaml` has no `plugins`
entry on purpose: the kind run needs no plugin, and a
Cluster pointing at a plugin that is not installed would
fail. The EKS script patches the entry in after the
cluster is Ready (`kubectl patch cluster ... plugins:
barman-cloud.cloudnative-pg.io, isWALArchiver: true,
barmanObjectName: postgres-cnpg-wal`); the operator
restarts the instances once, then the script waits for
Ready again.

Auth is Pod Identity, not access keys. The operator
creates a ServiceAccount named after the cluster
(`postgres-cnpg`, namespace `csi-demo`); Terraform binds
that service account to the WAL role, and the ObjectStore
sets `s3Credentials.inheritFromIAMRole: true`, so the
Barman sidecar uses the pod's role through the AWS SDK
default credential chain. No access keys are created,
stored, or committed. The bucket name comes from
`terraform output -raw cnpg_wal_bucket` (cluster name +
account id, so it is globally unique) and is substituted
into the ObjectStore with `envsubst`; it is never
hardcoded in a manifest. Retention is 30d in the
ObjectStore (Barman deletes older backups); the bucket
lifecycle rule is only a backstop for noncurrent
versions.

## RPO, defined

Two RPOs, because there are two ways to lose data:

- **Failover RPO** — the standby replay lag at the kill.
  If the primary dies and the standby is promoted, the
  promoted standby is missing the transactions the
  primary wrote after the standby's replay point. Worst
  standby is the headline (the most caught-up standby is
  what gets promoted, so the best case is the minimum).
- **Archive RPO** — the WAL not yet archived to S3. If
  the primary dies AND its volume is gone, the
  recoverable point is the last archived WAL; everything
  after it is lost.

`scripts/drills/rpo_measure.py` measures both from the
live cluster (`pg_current_wal_lsn()`,
`pg_stat_archiver`, `pg_stat_replication`, and the
Cluster status) and writes `evidence/rpo-<date>.json`.
It exits 0 when at least one RPO was measured and 2
when nothing could be measured; the evidence file is
still written with `measured: false` and the reason,
never a fake number. On kind the archive is not
configured (no S3, no plugin), so archive RPO is
recorded "not configured" and only the failover RPO is
measured.

## How to run it

EKS (one-day run): `scripts/eks/run_eks_day.sh` runs the
CNPG step (`scripts/eks/cnpg_failover_eks.sh`), which
installs cert-manager + the plugin, applies the
ObjectStore, patches the Cluster, takes the base backup,
and measures the RPO before the failover trials
(baseline) and after them (final). The WAL setup is
best-effort: if any of it fails, the drill continues
without archiving and the RPO file records the archive
as not configured — the failover timing does not depend
on the backup.

Kind (CI): the CNPG failover drill
(`scripts/drills/cnpg_failover_ci.sh`, run by
`.github/workflows/cnpg-failover-drill.yml`) runs the RPO
script at baseline and final; only the failover RPO is
measured there.

## Status: built, unmeasured

The bucket, role, ObjectStore, Backup, plugin wiring,
and RPO script are built and unit-tested (tests
`python/tests/test_rpo.py`, 17 tests); Terraform
validates. No RPO number exists yet: the kind drill
needs a push and a dispatch, and the EKS numbers need
the one-day run. No RPO number is quoted until a run
has written `evidence/rpo-<date>.json`.
