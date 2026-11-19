#!/usr/bin/env bash
# Install Dell's PowerScale CSI driver, chart dell/csi-isilon 2.18.1.
# We use the driver, we do not write one. The driver is Dell's code;
# what we own is the values file, the secret, and the manifests.
# Requires: helm, kubectl, a cluster, and helm/isilon-creds.yaml
# filled in from helm/isilon-creds.yaml.example (never committed).
# Also requires the snapshot CRDs: they ship with the chart in 2.x,
# verify with: kubectl get crd volumesnapshots.snapshot.storage.k8s.io
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -f "$ROOT/helm/isilon-creds.yaml" ]; then
  echo "Missing helm/isilon-creds.yaml. Copy helm/isilon-creds.yaml.example and fill in your OneFS host, user, and password."
  exit 1
fi
helm repo add dell https://dell.github.io/helm-charts
helm repo update
# Secret first: the driver needs it on start, or the controller
# pods crash-loop until it appears.
kubectl create namespace csi-isilon --dry-run=client -o yaml | kubectl apply -f -
kubectl -n csi-isilon create secret generic isilon-creds \
  --from-file=config="$ROOT/helm/isilon-creds.yaml" --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install isilon dell/csi-isilon --version 2.18.1 \
  --namespace csi-isilon --create-namespace \
  -f "$ROOT/helm/values.yaml"
kubectl -n csi-isilon wait --for=condition=ready pod -l app=csi-isilon-controller --timeout=300s || true
kubectl -n csi-isilon get pods -o wide
kubectl get csidriver csi-isilon.dellemc.com
