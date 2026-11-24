# Node failure: what actually happens, and what the drills measure

## The trap: a StatefulSet pod on a dead node stays Terminating

When a node dies without kubelet noticing the shutdown, the
pod on it enters Terminating and never finishes deleting,
because the kubelet that would confirm deletion is gone.
The StatefulSet controller guarantees at most one pod with
a given identity, so it will not create a replacement while
the old pod object exists. Recovery stalls forever without
operator intervention. This is Kubernetes behaving as
specified, not a misconfiguration. (Kubernetes docs, "Node
Shutdowns": "the pods that are part of a StatefulSet will
be stuck in terminating status on the shutdown node and
cannot move to a new running node.")

A Deployment behaves differently: its pods are
interchangeable, so the controller creates a replacement
elsewhere. That is not what this project runs. Postgres
here is a StatefulSet, one replica, stable identity
`postgres-0`.

## What the 30s tolerations do, and do not do

- Node failure detection takes about 40s: the
  kube-controller-manager marks the node NotReady after
  `node-monitor-grace-period` (default 40s) with no
  kubelet heartbeat.
- The tuned tolerations (`tolerationSeconds: 30` on
  `node.kubernetes.io/not-ready` and `unreachable`,
  down from the 300s default) start eviction about 30s
  after that, so eviction starts ~70s after the failure.
  Untuned it starts ~340s after.
- Eviction is not recovery. Eviction deletes the pod
  object; deletion cannot complete while the kubelet is
  dead, so the replacement is never created. The
  tolerations control when eviction *begins*. They are
  not the real lever for StatefulSet recovery.

## The two ways out, and their costs

1. **Out-of-service taint (the supported path).**
   `kubectl taint nodes <node> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute`
   Non-Graceful Node Shutdown, GA since Kubernetes 1.28.
   The pod garbage collector force-deletes pods on the
   node that do not tolerate the taint, and the
   attach/detach controller detaches their volumes
   immediately, so the StatefulSet can create the
   replacement on a surviving node. Preconditions: verify
   the node is really down (not restarting), and remove
   the taint after the node recovers.
2. **Force-delete the pod**
   (`kubectl delete pod <pod> --force --grace-period=0`).
   This only removes the record from the API; it does
   not kill any process on the node. If the node is
   actually alive, two pods write the same data:
   split-brain. Even when the node is dead, the volume
   stays attached until Kubernetes force-detaches it,
   which takes up to 6 minutes after the deletion fails.
   The replacement pod waits on the volume meanwhile.

## Drain is graceful, not failure

`kubectl drain` talks to a live kubelet, which
terminates the pod cleanly and lets the StatefulSet
reschedule it. There is no NotReady wait and no
toleration involved. The drain drill measures graceful
rescheduling. Do not quote a drain number as a failure
recovery number.

## The three cases in CI

`scripts/drills/node_failure_ci.sh`, run by
`.github/workflows/node-failure-drill.yml` on kind with
an in-cluster NFS provisioner (GitHub runners have
Docker; this build VM does not):

1. **Drain** — graceful rescheduling, timed drain-start
   to Ready and to serving queries.
2. **Hard stop, no intervention** — `docker kill` the
   node, watch 240s. Expected: stall. The pod stays
   Terminating and no replacement appears. A stall is
   the correct, documented result.
3. **Hard stop + out-of-service taint** — `docker kill`,
   wait for NotReady and eviction start, apply the
   taint, time docker-kill to Ready and to serving
   queries.

Results land in `evidence/node-failure-drill.json` and
as a workflow artifact. Scope: kind + NFS only. This
does not exercise the PowerScale CSI driver or OneFS.

## EKS equivalent

The same three cases run on the one-day EKS run
(`scripts/eks/run_eks_demo.sh` currently scripts the
drain only): terminate the EC2 instance instead of
`docker kill`. One extra detail there: an EBS volume
is tied to one Availability Zone, so a pod rescheduled
to another AZ cannot attach its volume — the
replacement must land in the same AZ, or the volume
must be EFS (shared) rather than EBS.
