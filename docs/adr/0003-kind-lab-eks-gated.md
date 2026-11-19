# ADR-0003: kind lab, EKS gated

Status: accepted

## Context

The project must be buildable for $0, and also be the
same manifests that run on a real cluster.

## Decision

kind is the lab path, with 1 control-plane and 2 workers.
EKS Terraform is gated off by `enable_eks = false`, and
is validated only, not applied, in the lab.

## Consequences

- Good: the whole project runs for $0, in CI, on every push.
- Good: one real EKS run, about $4.50 for a day, proves
  the same manifests against a real API.
- Bad: kind is not EKS. Node failure in kind is `docker stop`,
  not a real EC2 failure, and the network is a Docker
  bridge, not a VPC. Those limits are stated in the README.
