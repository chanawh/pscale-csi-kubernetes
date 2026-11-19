# One real EKS run, for a day

The kind version is the $0 version that gets you the
interview. One real EKS run is what turns "lab project"
into "ran on EKS". Do it once, for a day, then destroy it.

## Cost, one day, us-west-2

| Item | Cost for one day |
|---|---|
| EKS control plane, $73/month | ~$2.40 |
| 2 x t3.medium nodes, ~$60/month | ~$2.00 |
| EBS for the nodes, small | under $0.10 |
| Data transfer, lab scale | under $0.01 |
| **Total** | **about $4.50 for one day** |

Left running for a month, the same cluster is ~$135/month.
Do not leave it running. Apply, demo, destroy the same day.

## Steps

1. In `terraform/`, set `enable_eks = true` and apply.
2. `aws eks update-kubeconfig --name pscale-csi --region us-west-2`
3. Run `scripts/install_driver.sh` and `scripts/run_demo.sh`
   against the EKS cluster, with OneFS reachable from the VPC.
   This is the hard part: OneFS must be reachable from EKS,
   which means a VPN or a public IP, not a lab LAN. If you
   cannot route to OneFS from EKS, run the demo on kind
   and use EKS only for the cluster-creation proof.
4. `terraform destroy` the same day.

## After the run

Update the resume bullet: replace "in a $0 lab (kind +
Dell PowerScale CSI driver 2.18.1 + OneFS Simulator)"
with "on EKS (one-day lab run, destroyed same day)".
Keep the Simulator honest. The point is that the same
manifests ran against a real EKS API, not just kind.
