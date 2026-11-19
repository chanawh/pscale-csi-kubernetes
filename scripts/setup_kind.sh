#!/usr/bin/env bash
# Create the kind cluster: 1 control-plane, 2 workers, K8s 1.31.
# $0, no AWS account, no Docker Hub login needed for kind itself.
# Requires: kind, kubectl, Docker running.
# On the OneFS side, the workers must reach OneFS on the host LAN.
# See docs/ONEFS_CSI_SETUP.md for the networking note.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
kind create cluster --config "$ROOT/scripts/kind-config.yaml"
kubectl cluster-info
kubectl get nodes -o wide
