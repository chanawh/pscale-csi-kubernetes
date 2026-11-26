# CNPG WAL archive bucket (EKS only): the S3 bucket the Barman
# Cloud Plugin archives WAL segments and base backups to
# (k8s/cnpg/objectstore.yaml), and the IAM role the CNPG pods
# assume through Pod Identity to write there.
#
# Gated by enable_eks, like the rest of the EKS path: off by
# default, created on the one-day EKS run, destroyed with it.
# The bucket exists whenever EKS is on; archiving itself only
# starts when the Cluster carries the plugin entry
# (scripts/eks/cnpg_failover_eks.sh patches it in), so a run
# with --skip-cnpg leaves an empty bucket behind, not data.
#
# Auth is Pod Identity, not access keys: the CNPG operator
# creates a ServiceAccount named after the cluster
# (postgres-cnpg, namespace csi-demo), the association below
# binds that service account to the role, and the Barman
# sidecar (which runs in the instance pods) picks the
# credentials up from the Pod Identity agent through the AWS
# SDK default credential chain. The ObjectStore sets
# s3Credentials.inheritFromIAMRole: true, which tells
# barman-cloud to use the pod's role instead of a secret.
# No access keys are created, stored, or committed anywhere.
#
# Bucket name: cluster name + account id, so it is globally
# unique without a random suffix (the EKS script reads the
# name from `terraform output -raw cnpg_wal_bucket`, it is
# never hardcoded in a manifest). KMS: a dedicated key —
# the EKS secrets key is for etcd envelope encryption and
# its policy is root-only; the WAL key's policy grants the
# CNPG role exactly Encrypt/Decrypt/GenerateDataKey/
# DescribeKey. Lifecycle: Barman's retentionPolicy (30d,
# in the ObjectStore) is the primary cleanup; the rules
# here are a backstop — expire noncurrent versions after
# 30d, and abort incomplete multipart uploads after 7d
# (barman-cloud uploads large base backups multipart).

resource "aws_s3_bucket" "cnpg_wal" {
  count  = var.enable_eks ? 1 : 0
  bucket = "${var.cluster_name}-cnpg-wal-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${var.cluster_name} CNPG WAL archive (lab, one-day run)"
  }
}

resource "aws_s3_bucket_versioning" "cnpg_wal" {
  count  = var.enable_eks ? 1 : 0
  bucket = aws_s3_bucket.cnpg_wal[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "cnpg_wal_key" {
  statement {
    sid    = "Enable IAM User Permissions"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "Allow CNPG To Use The Key"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.cnpg_wal[0].arn]
    }
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }
}

resource "aws_kms_key" "cnpg_wal" {
  count                   = var.enable_eks ? 1 : 0
  description             = "${var.cluster_name} CNPG WAL archive encryption (lab, one-day run)"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.cnpg_wal_key.json
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cnpg_wal" {
  count  = var.enable_eks ? 1 : 0
  bucket = aws_s3_bucket.cnpg_wal[0].id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.cnpg_wal[0].arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cnpg_wal" {
  count  = var.enable_eks ? 1 : 0
  bucket = aws_s3_bucket.cnpg_wal[0].id

  rule {
    id     = "wal-retention-backstop"
    status = "Enabled"

    # Empty filter: the rule applies to the whole bucket
    # (the provider requires filter or prefix).
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_iam_role" "cnpg_wal" {
  count = var.enable_eks ? 1 : 0
  name  = "${var.cluster_name}-cnpg-wal"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "cnpg_wal_s3" {
  count = var.enable_eks ? 1 : 0
  name  = "${var.cluster_name}-cnpg-wal-s3"
  role  = aws_iam_role.cnpg_wal[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [aws_s3_bucket.cnpg_wal[0].arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        # Barman writes under <cluster>/wals/ and
        # <cluster>/base/; the prefix is the cluster
        # name, matching destinationPath in the
        # ObjectStore (k8s/cnpg/objectstore.yaml).
        Resource = ["${aws_s3_bucket.cnpg_wal[0].arn}/postgres-cnpg/*"]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = [aws_kms_key.cnpg_wal[0].arn]
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "cnpg_wal" {
  count           = var.enable_eks ? 1 : 0
  cluster_name    = aws_eks_cluster.main[0].name
  namespace       = "csi-demo"
  service_account = "postgres-cnpg"
  role_arn        = aws_iam_role.cnpg_wal[0].arn

  depends_on = [aws_eks_addon.pod_identity_agent]
}
