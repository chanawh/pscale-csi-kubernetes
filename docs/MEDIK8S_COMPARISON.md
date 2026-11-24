# Node remediation: this guard vs medik8s

Three ways to get a pod off a dead node, compared on mechanism,
recovery path, and false-positive safety. No live timing
comparison exists yet: the guard's timing and the medik8s
timing are both unmeasured in this repo, so the table below
compares design, not seconds.

## The contenders

| | This guard | medik8s Self Node Remediation (SNR) | medik8s Machine Deletion Remediation (MDR) |
|---|---|---|---|
| Detection | Node Health Check is not used; the guard reads the Ready condition + lastTransitionTime directly | Node Health Check operator (NHC): node NotReady/Unknown for a configured duration, then instantiates a remediation template | Same NHC detection |
| Remediation | Out-of-service taint; the pod is force-deleted and rescheduled on another node | Kernel watchdog: the node stops petting the watchdog, the watchdog reboots the node, the pod recovers in place when the kubelet returns | Deletes the Machine object (Cluster API); the machine controller provisions a replacement node |
| Recovery path | Reschedule elsewhere | Recover in place | Replace the node |
| If the node never comes back | Pod recovers on another node | Pod stays down (nothing to reboot) | Replacement node joins, pod reschedules |
| False-positive safety | Two sources must agree (Kubernetes + docker/EC2), plus a maintenance annotation; unknown answers refuse | Watchdog fencing: the node fences itself, so a partitioned node cannot keep writing — but a healthy node that loses API contact and reboots is an outage the operator caused | Deleting a Machine for a healthy node removes capacity and reschedules its pods; NHC thresholds are the only guard |
| Install | One CronJob + RBAC, stdlib Python, no operator | NHC + SNR operators (OperatorHub, v0.12.0 NHC, actively maintained, updated 2026) | NHC + MDR + Cluster API |
| Needs | kubectl or in-cluster API; docker (kind) or EC2 API (EKS) | Watchdog device on the node; NHC configured | Cluster API Machines |

## What SNR does that the guard does not

SNR's answer to a dead node is "reboot it and recover in
place." That is the right answer when the node is down because
of a transient fault (kernel panic, hung kubelet) and the
hardware is fine: the pod, its volume, and its node all come
back together, and there is no reschedule, no volume detach,
no AZ question. The guard cannot do that; it can only move
the pod elsewhere.

## What the guard does that SNR does not

SNR never reschedules. If the node is really dead — power,
hardware, terminated instance — the watchdog has nothing to
reboot, and the pod stays down until a human intervenes or
something else deletes the node. The guard's taint is the
recovery for that case: the pod moves to a live node and the
volume reattaches there. On EKS the EBS AZ binding still
applies (the volume cannot attach in another AZ), so the
guard's recovery is "same AZ, different node" for EBS, and
"any node" for EFS and PowerScale NFS.

## False positives, compared honestly

- The guard's worst case is tainting a live node: the pod is
  force-deleted and rescheduled while the old kubelet is still
  running, risking two writers on one volume. Its defense is
  the second source (docker/EC2) plus the maintenance
  annotation. The defense fails if both sources are wrong at
  once — for example, if the EC2 API reports an instance
  stopped while it is actually running, which should not
  happen, but "should not" is not a proof.
- SNR's worst case is rebooting a healthy node: the node loses
  API contact, the watchdog times out, the node reboots. Its
  defense is that the node fences itself — a partitioned node
  cannot keep writing while it reboots, because the reboot
  takes the kubelet down with it. The outage is real (the
  node's pods restart) but it is not corruption.
- MDR's worst case is deleting a healthy Machine: capacity is
  removed and every pod on it reschedules. Loud, but not
  corrupting.

SNR's failure mode is safer than the guard's. That is the
honest ranking, and it is why the guard's second source is a
hard requirement, not a nice-to-have.

## When to use which

- Node is down, hardware is fine, pod should come back where
  it was: SNR.
- Node is down, hardware is dead or the instance is gone, pod
  must move: the guard (or MDR, if the cluster is Cluster
  API-managed).
- Both: NHC can trigger SNR first and the guard's taint as the
  escalation if the node does not return. That combination is
  not built here; it is the obvious next step after the guard's
  live timing is measured.

## Status and sources

- medik8s Node Health Check operator v0.12.0 on OperatorHub,
  Self Node Remediation and Machine Deletion Remediation
  repositories active in 2026 (medik8s.io, OperatorHub).
  medik8s is a Red Hat-originated community project; no CNCF
  status is claimed here (unverified).
- This comparison is from documentation, not from running
  medik8s. A live timing comparison (same kill, guard vs SNR
  vs MDR) needs a real cluster and is pending.

## Verdict for this repo

The guard stays. It is 350 lines of stdlib Python with no
operator to install, it solves the case SNR cannot (dead
node, pod must move), and its false-positive defense is
explicit and testable. SNR is the better tool for the
transient case and the safer failure mode, and the repo
should say so rather than pretend the guard covers
everything.
