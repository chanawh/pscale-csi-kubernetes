# ADR-0007: Automate the out-of-service taint with a guarded controller

## Status

Accepted. Implemented in v1.2.0 (`guard/node_guard.py`, CronJob in
`k8s/guard/`). Live timing unmeasured; see docs/GUARD_DESIGN.md.

## Context

The node-failure drill (run 45339015253) proved two things. A
StatefulSet pod on a dead node does not recover on its own: it
sat Running/NotReady for 240s with no replacement, and the 30s
eviction tolerations do not change that, because eviction stalls
on the dead kubelet. And the out-of-service taint does recover
it, in ~15s once applied. The manual step is the problem: a
human has to notice, confirm the node is really down, and apply
the taint. In the drill that took 135s of flag lag before the
script applied it. Unattended, nobody applies it at all.

## Decision

Build a small guard (Python, stdlib only, ~350 lines) that runs
as a CronJob every 2 minutes and applies the out-of-service
taint only when three conditions all hold: the node has been
unreachable for 180s (from lastTransitionTime), a second source
outside Kubernetes confirms the instance is down (docker for
kind, EC2 API for EKS), and no maintenance annotation is set.
Dry-run mode, JSON-lines audit log, and auto-removal of its own
taint when the node recovers. It never removes a human-applied
taint and never acts on an unknown checker answer.

## Alternatives considered

- **Manual taint (status quo).** Works, measured, but slow and
  unattended means never. Kept as the fallback: the drill
  script still applies the taint by hand.
- **medik8s Self Node Remediation.** Reboots the node via a
  kernel watchdog and the pod recovers in place when the node
  rejoins. It does not reschedule elsewhere, so on a node that
  never comes back the pod stays down. Also an operator to
  install and run. See docs/MEDIK8S_COMPARISON.md.
- **Force-delete the pod.** Clears the stall but does not check
  the node is down; on a partitioned-but-alive node it risks
  two writers on one volume. Rejected.
- **A full operator (controller-runtime, CRDs).** More moving
  parts than the problem needs. A CronJob plus the API is
  enough, and it is testable without a cluster.

## Consequences

- Recovery becomes unattended, but only as fast as the guard's
  conditions allow: 180s unreachable + checker confirmation.
  The 15s taint-to-Ready number does not change; the wait
  before the taint does.
- A new failure mode appears: the guard itself. Its mitigations
  are the three conditions, dry-run first, and the audit log.
  The chaos test (dry-run on a healthy cluster, asserting no
  taint decision) runs in the drill workflow.
- RBAC: the guard can patch nodes. That permission is the
  dangerous one in the repo; it is scoped to nodes only and
  documented in k8s/guard/rbac.yaml.
