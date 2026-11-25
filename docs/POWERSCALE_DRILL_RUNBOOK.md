# PowerScale drill runbook (your machine)

The CI drill (`.github/workflows/node-failure-drill.yml`) measures
the same three cases on kind + in-cluster NFS. This runbook is
the PowerScale path: the same Postgres StatefulSet, the same
kill-and-taint drill, but the volume is a real PowerScale volume
provisioned by Dell's CSI driver on the OneFS Simulator. That is
the run that turns the PowerScale bullet from "designed" into
"measured". It cannot run in CI (no OneFS there) or in the build
VM (no container networking); it runs on your machine only.

## 0. Prerequisites

Docker running, `kind`, `kubectl`, `helm`. The OneFS Simulator
VM from Project 1 (cluster `nas2aws-onefs`, host 192.168.1.50),
on **Bridged** networking — see `docs/ONEFS_CSI_SETUP.md` §5,
and the simulator setup in the migration repo's
`docs/ONEFS_VIRTUAL_NODE.md`. The kind workers must reach
OneFS on ports 445 (NFS) and 8080 (Platform API).

## 1. OneFS side (once)

`docs/ONEFS_CSI_SETUP.md`: `/ifs/data/csi` path, SmartQuotas,
NFS export, System access zone. Fill in `helm/isilon-creds.yaml`
from `helm/isilon-creds.yaml.example` — never commit the
filled-in file.

## 2. Cluster + driver

```sh
bash scripts/setup_kind.sh      # 1 control-plane + 2 workers, K8s 1.31
bash scripts/install_driver.sh  # Dell csi-isilon 2.18.1 via Helm
```

## 3. Run the full demo (recommended)

```sh
bash scripts/run_demo.sh
```

This deploys Postgres on the `powerscale` StorageClass, writes
the row, then runs all four drills in order: snapshot/restore,
clone, expand 10 to 20 GiB, node failure. The node-failure
drill (`scripts/drills/node_failure.sh`) runs the same three
cases as the CI drill, but on the PowerScale volume: drain
(graceful reschedule), hard stop with no intervention
(expected stall, 240s watched), and hard stop + out-of-service
taint (timed to Ready and serving). It refuses to run unless
the Postgres PVC is on the `powerscale` StorageClass, so the
PowerScale evidence can never be measured on an NFS volume
by mistake. Evidence lands in
`evidence/node-failure-powerscale.json` — commit it, it is the
resume evidence. For the drill alone, deploy Postgres first
(`kubectl apply -f k8s/postgres-secret.yaml k8s/pvc-postgres.yaml
k8s/postgres-statefulset.yaml`, wait Ready, run `k8s/test-job.yaml`)
then `bash scripts/drills/node_failure.sh`.

## 4. What to expect

- Drain (case 1, CI reference on NFS): Ready 2s, serving 5s.
  The PowerScale drill times the same drain on the PowerScale
  volume — expect the same shape (graceful reschedule, the
  volume detaches and reattaches).
- Hard stop, no intervention (case 2): expect a stall, the pod
  Running/NotReady with no replacement for the full 240s
  watched — the same as CI run 45336965561 on NFS. The
  evidence records deletionTimestamp, tolerations, and node
  taints, which decide whether eviction started.
- Hard failure + taint (case 3, CI reference on NFS): Ready
  195s, serving 198s, most of it the node sitting in `Unknown`
  while the flag lagged — the taint itself recovered the pod
  in ~15s once applied. Expect the same shape on PowerScale;
  the number that matters for the resume is the serving
  time.
- The row `csi-powerscale-proof` must read back after every
  case. If it does not, the volume did not reattach and the
  run does not count.

## 5. Teardown

```sh
docker start <stopped-node>    # the drill prints the exact commands
kubectl taint nodes <node> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute-
kind delete cluster --name pscale-csi
```

Also delete the `/ifs/data/csi/pvc-*` directories on the
simulator if you want a clean slate for the next run.

## 6. Report back

The three cases from `evidence/node-failure-powerscale.json`
(drain Ready/serving, stall true/false, taint Ready/serving),
plus whether the snapshot/clone/expand drills passed. Those
go on the resume and into `docs/NODE_FAILURE_DRILL.md` next
to the CI numbers.
