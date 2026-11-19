# ADR-0004: Quotas on

Status: accepted

## Context

A PVC asks for 10 GiB. Something must stop the volume
growing past that.

## Decision

Set `enableQuota: true` in the Helm values, and require
SmartQuotas on OneFS. The driver sets a quota per volume
when it creates it.

## Consequences

- Good: a volume cannot fill OneFS by growing past its
  PVC size.
- Good: expansion works, because the driver grows the
  quota when the PVC grows.
- Bad: SmartQuotas must be enabled on the cluster, or
  volume creation fails. That is a setup step, not an
  optional extra, and it is in docs/ONEFS_CSI_SETUP.md.
