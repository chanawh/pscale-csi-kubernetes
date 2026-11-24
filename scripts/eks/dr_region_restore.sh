#!/usr/bin/env bash
# Cross-region DR: copy the latest EBS snapshot of the Postgres
# volume to region B, restore it there, and verify the row.
# Measures RPO (how old the restored data is) and RTO (restore
# start to row verified). Writes evidence/dr-region.json.
#
# NOT run: needs a second EKS cluster in region B, a snapshot in
# region A, and an AWS account. This script is validated by
# bash -n and tests only. See docs/DR_REGION.md.
#
# Usage:
#   REGION_A=us-west-2 REGION_B=us-east-1 RESTORE_AZ=us-east-1a \
#     VOLUME_ID=vol-xxx KUBE_CONTEXT=<region-B-cluster-context> \
#     bash scripts/eks/dr_region_restore.sh
set -euo pipefail
REGION_A="${REGION_A:?set REGION_A}"
REGION_B="${REGION_B:?set REGION_B}"
RESTORE_AZ="${RESTORE_AZ:?set RESTORE_AZ, e.g. us-east-1a}"
VOLUME_ID="${VOLUME_ID:?set VOLUME_ID of the Postgres EBS volume}"
KUBE_CONTEXT="${KUBE_CONTEXT:?set KUBE_CONTEXT of the region-B cluster}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EVIDENCE="$ROOT/evidence/dr-region.json"
TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

T0=$(date +%s)
echo "== latest snapshot of $VOLUME_ID in $REGION_A =="
SNAPSHOT_ID=$(aws ec2 describe-snapshots --region "$REGION_A" \
  --filters "Name=volume-id,Values=$VOLUME_ID" \
  --query "sort_by(Snapshots, &StartTime)[-1].SnapshotId" --output text)
SNAPSHOT_TIME=$(aws ec2 describe-snapshots --region "$REGION_A" \
  --snapshot-ids "$SNAPSHOT_ID" \
  --query "Snapshots[0].StartTime" --output text)
VOLUME_SIZE=$(aws ec2 describe-snapshots --region "$REGION_A" \
  --snapshot-ids "$SNAPSHOT_ID" \
  --query "Snapshots[0].VolumeSize" --output text)
echo "snapshot $SNAPSHOT_ID taken $SNAPSHOT_TIME (${VOLUME_SIZE}Gi)"

echo "== copy snapshot to $REGION_B =="
COPY_ID=$(aws ec2 copy-snapshot --region "$REGION_B" \
  --source-region "$REGION_A" --source-snapshot-id "$SNAPSHOT_ID" \
  --description "pscale-csi DR copy of $SNAPSHOT_ID" \
  --query "SnapshotId" --output text)
aws ec2 wait snapshot-completed --region "$REGION_B" --snapshot-ids "$COPY_ID"
echo "copy $COPY_ID completed"

echo "== create volume from the copy in $RESTORE_AZ =="
RESTORED_VOL=$(aws ec2 create-volume --region "$REGION_B" \
  --availability-zone "$RESTORE_AZ" --snapshot-id "$COPY_ID" \
  --volume-type gp3 --query "VolumeId" --output text)
aws ec2 wait volume-available --region "$REGION_B" --volume-ids "$RESTORED_VOL"
echo "restored volume $RESTORED_VOL"

echo "== static PV + PVC in region B, then Postgres =="
cat > "$TMPDIR_WORK/pv.yaml" <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: postgres-data-dr
spec:
  capacity:
    storage: ${VOLUME_SIZE}Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  claimRef:
    namespace: csi-demo
    name: postgres-data-ebs
  awsElasticBlockStore:
    volumeID: $RESTORED_VOL
    fsType: ext4
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data-ebs
  namespace: csi-demo
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${VOLUME_SIZE}Gi
  storageClassName: ""
  volumeName: postgres-data-dr
EOF
kubectl --context "$KUBE_CONTEXT" apply -f "$TMPDIR_WORK/pv.yaml"
kubectl --context "$KUBE_CONTEXT" apply -f "$ROOT/k8s/postgres-secret.yaml"
# The EKS StatefulSet file also creates the headless postgres
# Service the test job connects to. It claims postgres-data-ebs,
# which is now statically bound to the restored volume.
kubectl --context "$KUBE_CONTEXT" apply -f "$ROOT/k8s/eks/postgres-statefulset-ebs.yaml"
kubectl --context "$KUBE_CONTEXT" -n csi-demo wait --for=condition=ready pod -l app=postgres --timeout=600s
kubectl --context "$KUBE_CONTEXT" -n csi-demo apply -f "$ROOT/k8s/test-job.yaml"
kubectl --context "$KUBE_CONTEXT" -n csi-demo wait --for=condition=complete job/csi-test-write --timeout=180s
kubectl --context "$KUBE_CONTEXT" -n csi-demo logs job/csi-test-write | tee "$TMPDIR_WORK/job.log"
grep -q "csi-powerscale-proof" "$TMPDIR_WORK/job.log"
T1=$(date +%s)

RPO=$((T0 - $(date -d "$SNAPSHOT_TIME" +%s)))
RTO=$((T1 - T0))
mkdir -p "$ROOT/evidence"
cat > "$EVIDENCE" <<EOF
{
  "scope": "EKS cross-region DR: snapshot copy region A to region B, restore, verify row",
  "source_region": "$REGION_A",
  "target_region": "$REGION_B",
  "restore_az": "$RESTORE_AZ",
  "volume_id": "$VOLUME_ID",
  "snapshot_id": "$SNAPSHOT_ID",
  "snapshot_time": "$SNAPSHOT_TIME",
  "copied_snapshot_id": "$COPY_ID",
  "restored_volume_id": "$RESTORED_VOL",
  "rpo_seconds": $RPO,
  "rto_seconds": $RTO,
  "row_verified": true
}
EOF
echo "DR restore complete: RPO ${RPO}s, RTO ${RTO}s, row verified"
echo "evidence written to $EVIDENCE"
