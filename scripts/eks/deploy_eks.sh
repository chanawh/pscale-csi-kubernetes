#!/usr/bin/env bash
# Deploy the EKS path: Terraform (EKS + EBS/EFS CSI addons +
# Pod Identity + EFS) -> kubeconfig -> snapshot controller ->
# EKS manifests -> observability stack.
#
# Real AWS, real money: about $4.50 for one day left running,
# ~$135/month if you forget it. Run scripts/eks/destroy_eks.sh
# the same day. Requires: aws CLI configured, terraform,
# kubectl, helm, envsubst (gettext).
#
# This script has NOT been run from the build VM (no AWS
# account there). It is the operator's one-day run; see
# docs/REAL_EKS_ONE_DAY.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REGION="${AWS_REGION:-us-west-2}"
CLUSTER="${CLUSTER_NAME:-pscale-csi}"
# Node count. Default 2 (the runbook cost table). The driver
# passes 3 when the AZ check needs a second node in the
# Postgres volume's AZ (EKS_NODE_DESIRED_SIZE=3); keep this
# in step with the driver's terraform apply or the re-apply
# here scales the group back.
NODE_DESIRED_SIZE="${NODE_DESIRED_SIZE:-2}"

echo "== Terraform: EKS cluster, node group, CSI addons, EFS =="
cd "$ROOT/terraform"
terraform init -input=false
terraform apply -input=false -auto-approve -var="enable_eks=true" -var="region=$REGION" -var="cluster_name=$CLUSTER" -var="node_desired_size=$NODE_DESIRED_SIZE"

echo
echo "== Kubeconfig =="
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
kubectl get nodes

echo
echo "== Snapshot controller (not part of the EBS CSI addon) =="
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.6.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.6.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.6.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.6.0/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.6.0/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml

echo
echo "== EKS storage manifests =="
EFS_FILE_SYSTEM_ID="$(terraform output -raw efs_file_system_id)"
export EFS_FILE_SYSTEM_ID
echo "EFS filesystem: $EFS_FILE_SYSTEM_ID"
kubectl create namespace csi-demo --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$ROOT/k8s/eks/storageclass-ebs.yaml"
envsubst < "$ROOT/k8s/eks/storageclass-efs.yaml" | kubectl apply -f -
kubectl apply -f "$ROOT/k8s/eks/snapshotclass-ebs.yaml"
kubectl apply -f "$ROOT/k8s/postgres-secret.yaml"
kubectl apply -f "$ROOT/k8s/eks/pvc-postgres-ebs.yaml"
kubectl apply -f "$ROOT/k8s/eks/pvc-shared-efs.yaml"
kubectl apply -f "$ROOT/k8s/eks/postgres-statefulset-ebs.yaml"
kubectl -n csi-demo wait --for=condition=ready pod -l app=postgres --timeout=600s
kubectl -n csi-demo get pvc

echo
echo "== Observability (kube-prometheus-stack) =="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install observability prometheus-community/kube-prometheus-stack \
  --namespace observability --create-namespace \
  -f "$ROOT/helm/observability-values.yaml"
kubectl -n observability get pods

echo
echo "== Done. Next: bash scripts/eks/run_eks_demo.sh =="
echo "== Same day: bash scripts/eks/destroy_eks.sh =="
