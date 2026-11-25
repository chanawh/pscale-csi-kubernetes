# Node-down guard design

The guard (`guard/node_guard.py`, CronJob in `k8s/guard/`) automates
the one recovery the drill proved works: the out-of-service taint.
It exists because the manual step it replaces is slow and easy to
get wrong, and the wrong version corrupts data.

## The measured fact

CI drill run 45339015253 (kind + in-cluster NFS,
`evidence/node-failure-drill.json`): after a hard node kill the
Postgres StatefulSet pod sat Running/NotReady for 240s with no
replacement. The out-of-service taint recovered it in ~15s (198s
from the kill; most of that was the drill script waiting on a
lagging NotReady flag, not Kubernetes). Tolerations alone never
recover the pod: they start eviction, and eviction of a pod on a
dead node stalls because the kubelet that would confirm deletion
is dead. The StatefulSet will not create a replacement while the
old pod object exists. That is the at-most-one guarantee doing its
job. The taint is the supported way out (GA since Kubernetes
1.28): it force-deletes the pod and detaches the volume
immediately.

## Why not force-delete

`kubectl delete pod --force` also clears the stall, and it is
the first thing most people reach for. The guard does not use
it, for two reasons:

1. **Two writers.** A force delete does not check whether the
   node is actually down. If the node is alive but partitioned
   (network, not power), the old kubelet keeps the pod running
   against the same volume while the StatefulSet starts a second
   pod on another node against the same volume. Two Postgres
   processes, one data directory: corruption. The taint has the
   same risk in principle, which is why the guard's second
   condition exists — it must confirm the instance is down
   through a source outside Kubernetes before it acts.
2. **No audit trail.** A force delete is a kubectl one-liner
   with no record of why. The guard writes one JSON line per
   node per run (decision + reason), so the taint is always
   explainable after the fact.

## The three conditions (all must hold)

1. **Unreachable long enough.** The node's Ready condition has
   been False or Unknown for at least `--unreachable-seconds`
   (default 180s), measured from the condition's
   `lastTransitionTime`, not from when the guard first noticed.
   The guard is a stateless CronJob; it reads the timestamp from
   the API, so it needs no memory between runs. 180s covers the
   ~40s node-monitor grace period plus the 30s eviction
   toleration, with margin for a slow flag.
2. **A second source confirms the instance is down.**
   `--checker kind`: the kind container is stopped (`docker
   inspect`). `--checker aws`: the EC2 instance is stopped or
   terminated (`aws ec2 describe-instances`). If the checker
   cannot answer (docker missing, AWS CLI error, no providerID),
   it returns "unknown" and the guard refuses. A refused taint
   is a safe outcome; a wrong taint is a data-corruption
   outcome.
3. **No maintenance annotation.** A node carrying
   `csi-guard/maintenance: "true"` is never tainted, whatever
   else is true. This is the human override for planned work.

## What the guard never does

- It never taints a node that is Ready.
- It never taints on a single source of truth. Kubernetes
  saying NotReady is not enough; the checker must agree.
- It never removes a taint it did not apply. Auto-removal only
  fires when the node is Ready again AND carries the marker
  annotation (`csi-guard/tainted-by: node-guard`). A
  human-applied out-of-service taint is left alone.
- It never guesses. Unknown checker answers, missing
  `lastTransitionTime`, and API errors all end in refusal.

## Deployment

- **EKS:** CronJob `k8s/guard/cronjob.yaml` (every 2 minutes,
  `python:3.12-slim`, in-cluster API client, `--checker aws`),
  RBAC in `k8s/guard/rbac.yaml` (get/list/watch/patch on nodes
  only), script from ConfigMap `k8s/guard/configmap.yaml`
  (generated from `guard/node_guard.py` by
  `guard/generate_configmap.py`; a test asserts the two match
  byte for byte).
- **kind / local:** run the script directly, because the
  in-cluster pod has no docker socket for the kind checker:
  `python3 guard/node_guard.py --client kubectl --checker kind
  --dry-run`. The same command is the false-positive test
  (`scripts/drills/guard_chaos_test.sh`).
- **Dry-run:** `--dry-run` decides and logs, applies nothing.
  Run it first on any new cluster and read the audit log
  before allowing live mode.

## Testing

- Unit tests (`python/tests/test_guard.py`, fake client +
  fake checker): the full decision matrix — healthy skip,
  too-short skip, taint, maintenance refusal, instance-running
  refusal, checker-unknown refusal, dry-run, auto-removal,
  human-taint untouched, missing transition time. 15 tests.
- Live logic test: the guard was run against fake `kubectl`
  and `docker` binaries (one healthy node, one stopped node)
  and issued exactly the taint + marker calls for the dead
  node and nothing for the healthy one.
- Chaos test (`scripts/drills/guard_chaos_test.sh`, wired
  into `.github/workflows/node-failure-drill.yml`): dry-run
  against the healthy CI kind cluster, asserting no taint
  decision of any kind. This runs on the next manual drill
  dispatch; it has not run yet (no push in this change).

## What is still unmeasured

- **Live taint timing by the guard.** The manual taint took
  ~15s in run 45339015253. The guard's own timing is
  measured by `.github/workflows/guard-live-drill.yml`
  (`scripts/drills/guard_live_ci.sh`): 3 live-guard timing
  trials on a 2-minute cadence (the production CronJob
  cadence) plus 3 refusal trials (a paused node the guard
  must refuse). Not run yet — it needs a push and a manual
  dispatch. Expected as built: kill to serving ~240-360s
  (median ~300s), slower than the manual 198s, because the
  180s unreachable threshold plus up to 120s of CronJob
  wait dominate; the guard's value as built is automation
  plus triple confirmation, not speed. To beat 198s the
  loop must be shortened (lower threshold and/or tighter
  schedule) — a design decision, not taken here. The
  evidence file is `evidence/guard-live.json`.
- **False-positive rate over time.** The chaos test proves
  one healthy cluster, and the live drill adds 3 refusal
  trials on a paused node. A guard that runs every 2
  minutes for weeks is a different claim; the audit log is
  the data for it, and there is none yet.
- **AWS checker.** Written and unit-testable only through the
  fake checker; the real `aws ec2 describe-instances` path
  has never run, because there is no AWS account in this
  environment. It runs on the EKS one-day run.
