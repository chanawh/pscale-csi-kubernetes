#!/usr/bin/env bash
# Destroy the EKS lab the same day it was built.
# Order matters: delete the workloads and PVCs first (so
# EBS volumes and EFS access points are released by the CSI
# drivers), uninstall observability, then terraform destroy
# (cluster, node group, addons, EFS, KMS key scheduled for
# deletion). Skipping the PVC step can orphan EBS volumes
# that keep billing after the cluster is gone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REGION="${AWS_REGION:-us-west-2}"
CLUSTER="${CLUSTER_NAME:-pscale-csi}"

echo "== Delete workloads and PVCs (releases EBS/EFS volumes) =="
kubectl delete namespace csi-demo --ignore-not-found --timeout=300s || true

echo
echo "== Uninstall observability =="
helm uninstall observability --namespace observability || true
kubectl delete namespace observability --ignore-not-found --timeout=300s || true

echo
echo "== Terraform destroy =="
cd "$ROOT/terraform"
terraform destroy -input=false -auto-approve -var="enable_eks=true" -var="region=$REGION" -var="cluster_name=$CLUSTER"

echo
echo "== Leftover check (should print nothing) =="
echo "EBS volumes tagged for this cluster:"
aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned" \
  --query 'Volumes[].VolumeId' --output text || true
echo "EFS filesystems:"
# EFS describe output has no Name field (the name is a tag);
# the creation token is "${cluster_name}-efs" (terraform/efs.tf).
aws efs describe-file-systems --region "$REGION" \
  --creation-token "${CLUSTER}-efs" \
  --query 'FileSystems[].FileSystemId' --output text || true

echo
echo "== Done. KMS key deletion is scheduled (7-day window); =="
echo "== that is the minimum AWS allows, it bills nothing.  =="
