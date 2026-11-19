# ADR-0005: Postgres single replica, not clustered

Status: accepted

## Context

The demo needs a stateful workload to prove the storage
works.

## Decision

One Postgres replica, on one PVC. The point is the
storage, not HA Postgres.

## Consequences

- Good: the demo is simple, and a failure is clearly
  a storage failure, not a Postgres clustering failure.
- Good: one replica is enough to prove snapshot, clone,
  expand, and node failure.
- Bad: this is not a production database. A real
  Postgres deployment would use Patroni, or a managed
  service, and that is out of scope here.
