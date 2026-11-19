# ADR-0002: NFS ReadWriteMany, not block ReadWriteOnce

Status: accepted

## Context

A PVC needs an access mode, and the driver needs to
support it.

## Decision

Use NFS, ReadWriteMany, which is what the PowerScale
driver supports. Do not pretend block storage exists
here.

## Consequences

- Good: many pods can mount the same volume at once,
  which block storage cannot do.
- Good: the mode matches the storage, so there is no
  mismatch between what Kubernetes asks for and what
  OneFS can give.
- Bad: NFS throughput is network-bound, and NFS locking
  is weaker than block locking. A workload that needs
  block IOPS should not use this driver.
