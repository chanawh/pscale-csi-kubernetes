# Postgres HA: StatefulSet + guard vs CloudNativePG

The repo's Postgres is a single-replica StatefulSet on purpose
(ADR-0005): one pod isolates storage behavior, so the drill
measures the volume, not the database. That is the right shape
for a storage project and the wrong shape for a highly
available database. This doc compares it against the
operator-managed alternative, and gives the runbook for
measuring the difference.

## Why CloudNativePG

CloudNativePG (CNPG) is the comparison because it is the only
Postgres operator at CNCF Incubating (accepted 10 Nov 2026;
sandbox Jan 2025; v1.30.1), it uses a primary/standby
architecture with native streaming replication, and it needs
no external coordination service — no etcd, no Patroni DCS.
Crunchy Postgres Operator (PGO) is the other serious option,
but it carries more moving parts for the same comparison, and
Zalando's Patroni operator needs an etcd cluster just to decide
who is primary. CNPG's failover decision lives in the operator
itself. That makes the comparison clean: operator-managed
replication vs StatefulSet + guard, on the same kill, same
storage, same row.

## The two architectures

| | StatefulSet + guard (this repo) | CloudNativePG |
|---|---|---|
| Replicas | 1 (ADR-0005, on purpose) | 2 (primary + standby; `instances: 2` in `k8s/cnpg/cluster.yaml`) |
| Data copies | 1, on one volume | 2, one per pod, streaming replication |
| Node failure | Pod must move; volume detaches and reattaches; the guard applies the out-of-service taint | Operator promotes the standby to primary; the standby's volume is already attached on a live node |
| RPO | 0 if the volume survives (the data is on the disk, not in the pod) | 0 if the standby is caught up; small lag window if replication is behind at the kill |
| RTO driver | Detection + taint + detach/attach + Postgres start | Detection + promotion + client reconnect |
| What the client sees | Connection drops until the pod is Ready on the new node | Connection drops until promotion completes and the service points at the new primary |
| AZ loss (EBS) | Volume is AZ-bound; the pod can only recover in the same AZ | Same AZ binding per volume, but the standby can live in another AZ, so the primary can move AZs |
| Failure modes added | The guard (see docs/GUARD_DESIGN.md) | The operator itself, replication lag, split-brain on network partition (fencing via `fencing` / primary update strategy) |
| Cost | 1 volume | 2 volumes + operator |

## What the comparison measures (runbook)

Run on kind + NFS first ($0), then on EKS + EBS. Same kill
in both cases: `docker kill` the node (kind) or terminate
the instance (EKS), then time to serving queries, and check
the row.

### kind + NFS

```sh
# 1. Install the operator (CNPG 1.30.1)
kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/v1.30.1/releases/cnpg-1.30.1.yaml
kubectl wait --for=condition=Available deployment/cnpg-controller-manager -n cnpg-system --timeout=300s
# 2. Create the 2-replica cluster (k8s/cnpg/cluster.yaml: storageClassName nfs).
# Apply the bootstrap secret first: CNPG requires it to be a
# kubernetes.io/basic-auth secret with username/password keys,
# username matching the owner. k8s/postgres-secret.yaml does
# not qualify (its keys are POSTGRES_USER and friends), so the
# cluster has its own secret, k8s/cnpg/secret.yaml.
kubectl apply -f k8s/cnpg/secret.yaml
kubectl apply -f k8s/cnpg/cluster.yaml
kubectl wait --for=condition=Ready cluster/postgres-cnpg -n csi-demo --timeout=600s
# 3. Write the same row the StatefulSet drill uses.
# psql needs the password from the bootstrap secret, and the
# one-shot pod needs --restart=Never (a plain run would
# restart the finished container forever).
PGPASSWORD=$(kubectl -n csi-demo get secret postgres-cnpg-secret -o jsonpath='{.data.password}' | base64 -d)
kubectl -n csi-demo run cnpg-write --rm -i --restart=Never --image=postgres:16 --env PGPASSWORD="$PGPASSWORD" -- \
  psql -h postgres-cnpg-rw -U postgres -d csi_demo -c \
  "CREATE TABLE IF NOT EXISTS csi_proof (id INT PRIMARY KEY, note TEXT); INSERT INTO csi_proof VALUES (1, 'csi-powerscale-proof') ON CONFLICT (id) DO NOTHING; SELECT * FROM csi_proof;"
# 4. Kill the node running the primary, time to serving.
# The primary is authoritative from the cluster status,
# not from a label selector: CNPG's pod labels vary by
# version, .status.currentPrimary does not.
PRIMARY=$(kubectl -n csi-demo get cluster postgres-cnpg -o jsonpath='{.status.currentPrimary}')
PRIMARY_NODE=$(kubectl -n csi-demo get pod "$PRIMARY" -o jsonpath='{.spec.nodeName}')
T0=$(date +%s); docker kill "$PRIMARY_NODE"
# 5. Poll the read-write service until the row reads back
until kubectl -n csi-demo run cnpg-read --rm -i --restart=Never --image=postgres:16 --env PGPASSWORD="$PGPASSWORD" -- \
  psql -h postgres-cnpg-rw -U postgres -d csi_demo -tAc "SELECT note FROM csi_proof WHERE id=1;" 2>/dev/null | grep -q csi-powerscale-proof; do sleep 2; done
echo "CNPG failover to serving: $(( $(date +%s) - T0 ))s"
# 6. Record: failover seconds, which pod became primary, replication lag at kill (pg_stat_replication), row intact
```

### EKS + EBS

Same steps, with `storageClassName: ebs-gp3` in the cluster
manifest and an EC2 termination instead of `docker kill`.
The standby should be scheduled in a different AZ (the
cluster manifest sets no topology constraint; add
`topologySpreadConstraints` if the scheduler packs both
pods in one AZ).

## Expected shape (not numbers)

- CNPG should recover faster than StatefulSet + guard on the
  same kill, because promotion does not wait for a volume
  detach/attach cycle. The guard's path is detect (180s) +
  taint + detach/attach + start; CNPG's is detect + promote.
- CNPG's RPO is not automatically zero: if the standby lags
  at the kill, the promoted primary is missing the last
  transactions. The runbook checks the row, but a row written
  minutes before the kill does not prove zero lag; a write
  load during the kill would. That is a harder test and is
  not in this runbook.
- CNPG's failure mode the StatefulSet does not have: a
  network partition can leave two pods both believing they
  are primary. CNPG fences with its primary update strategy;
  the runbook does not test partition behavior.

## Status: drill built, unmeasured

The drill exists: `scripts/drills/cnpg_failover_ci.sh`
(run by `.github/workflows/cnpg-failover-drill.yml`,
manual dispatch) runs 3 failover trials on kind + NFS,
records kill to new-primary Ready and to serving per
trial, and writes the median to
`evidence/cnpg-failover.json`. It FAILED on its first
dispatch (run 45529763004, 25 Nov 2026; the error is
only in the run logs — no evidence artifact was
written). The most likely cause is a race in the setup:
the test row is written with a single psql attempt, so
if the read-write endpoint lags the cluster reporting
Ready, that one attempt fails and the drill dies before
trial 1. The fix is local (commit bbec4a0: the setup row
write retries up to 5 times, 15s apart); it needs a push
and a re-dispatch. No CNPG number is quoted until the
drill has run and the evidence is committed. The
StatefulSet numbers it would be compared against are
measured (drill run 45339015253: drain serving 5s, hard
kill + taint serving 198s from kill).

The comparison itself is now built: `docs/HA_COMPARISON.md`
(the measured version — CNPG HA vs single replica with
the manual taint vs single replica with the guard, plus
the RPO, as one table from the drill evidence), the
harness `scripts/drills/cnpg_compare_ci.sh`, and the
workflow `.github/workflows/ha-comparison-drill.yml`.
The RPO alongside is `docs/WAL_ARCHIVE.md` (Barman Cloud
plugin, archive to S3 on EKS; on kind the archive is not
configured, so only the failover RPO is measured).
