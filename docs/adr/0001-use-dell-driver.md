# ADR-0001: Use Dell's CSI driver, do not write one

Status: accepted

## Context

Kubernetes needs a CSI driver to use PowerScale storage.

## Decision

Install Dell's `csi-isilon` driver, version 2.18.1, with
Helm. Configure it with `helm/values.yaml` and a secret.
Do not write, fork, or vendor the driver.

## Consequences

- Good: the driver is tested by Dell, supports snapshots,
  cloning, expansion, and quotas, and is what a real
  employer uses.
- Good: the project is about operating storage, not
  about writing gRPC servers.
- Bad: we are dependent on Dell's release cadence and
  on the chart's values structure, which changes between
  versions. The chart version is pinned to 2.18.1 for
  that reason.
