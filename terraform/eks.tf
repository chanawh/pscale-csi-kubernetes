# EKS: the real-AWS path. Gated by enable_eks = false by default.
# kind is the $0 lab path (PowerScale CSI on OneFS Simulator);
# EKS is the same project on a real AWS cluster, with the AWS
# CSI drivers alongside: EBS (block, ReadWriteOnce) and EFS
# (file, ReadWriteMany), plus observability. Control plane
# ~$73/month, 2 x t3.medium nodes ~$60/month, so ~$135/month
# left running, about $4.50 for one day. Lab only: enable it,
# demo it, destroy it the same day. See ADR-0006.
#
# Validated with terraform fmt/validate only. Not applied
# from this VM: no AWS account is connected here. The first
# real apply is a one-day run on the operator's account,
# see docs/REAL_EKS_ONE_DAY.md.

data "aws_vpc" "default" {
  count   = var.enable_eks ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = var.enable_eks ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }
}

# KMS key for EKS secrets encryption (envelope encryption of
# Kubernetes Secrets in etcd). Lab key: destroyed with the
# cluster, deletion window is the minimum 7 days. The explicit
# key policy is the AWS default (root account full access);
# EKS accesses the key through grants, not the key policy.
# The policy is written out because checkov (CKV2_AWS_64)
# requires a defined key policy.
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "eks_secrets_key" {
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
}

resource "aws_kms_key" "eks_secrets" {
  count                   = var.enable_eks ? 1 : 0
  description             = "${var.cluster_name} EKS secrets encryption (lab, one-day run)"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.eks_secrets_key.json
}

resource "aws_iam_role" "eks_cluster" {
  count = var.enable_eks ? 1 : 0
  name  = "${var.cluster_name}-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  count      = var.enable_eks ? 1 : 0
  role       = aws_iam_role.eks_cluster[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "main" {
  count    = var.enable_eks ? 1 : 0
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster[0].arn
  version  = var.cluster_version

  # Control-plane logs to CloudWatch: the first place to look
  # when the API server or scheduler misbehaves on EKS.
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks_secrets[0].arn
    }
    resources = ["secrets"]
  }

  vpc_config {
    subnet_ids              = data.aws_subnets.default[0].ids
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

resource "aws_iam_role" "eks_nodes" {
  count = var.enable_eks ? 1 : 0
  name  = "${var.cluster_name}-nodes"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_nodes_worker" {
  count      = var.enable_eks ? 1 : 0
  role       = aws_iam_role.eks_nodes[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_nodes_cni" {
  count      = var.enable_eks ? 1 : 0
  role       = aws_iam_role.eks_nodes[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_nodes_registry" {
  count      = var.enable_eks ? 1 : 0
  role       = aws_iam_role.eks_nodes[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_eks_node_group" "main" {
  count           = var.enable_eks ? 1 : 0
  cluster_name    = aws_eks_cluster.main[0].name
  node_group_name = "${var.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes[0].arn
  subnet_ids      = data.aws_subnets.default[0].ids
  instance_types  = [var.node_instance_type]

  scaling_config {
    desired_size = var.node_desired_size
    max_size     = var.node_max_size
    min_size     = var.node_min_size
  }

  # Lab nodes: allow the node-drain drill to move pods without
  # fighting PodDisruptionBudgets that do not exist in the lab.
  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_nodes_worker,
    aws_iam_role_policy_attachment.eks_nodes_cni,
    aws_iam_role_policy_attachment.eks_nodes_registry,
  ]
}

# --- EKS addons: AWS CSI drivers + core networking ---
# Pod Identity (not IRSA) gives each CSI controller its own
# least-privilege IAM role: no OIDC thumbprint to maintain,
# and the role is bound to one namespace + service account.

resource "aws_iam_role" "ebs_csi" {
  count = var.enable_eks ? 1 : 0
  name  = "${var.cluster_name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count      = var.enable_eks ? 1 : 0
  role       = aws_iam_role.ebs_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  count           = var.enable_eks ? 1 : 0
  cluster_name    = aws_eks_cluster.main[0].name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi[0].arn
}

resource "aws_iam_role" "efs_csi" {
  count = var.enable_eks && var.enable_efs ? 1 : 0
  name  = "${var.cluster_name}-efs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  count      = var.enable_eks && var.enable_efs ? 1 : 0
  role       = aws_iam_role.efs_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "efs_csi" {
  count           = var.enable_eks && var.enable_efs ? 1 : 0
  cluster_name    = aws_eks_cluster.main[0].name
  namespace       = "kube-system"
  service_account = "efs-csi-controller-sa"
  role_arn        = aws_iam_role.efs_csi[0].arn
}

resource "aws_eks_addon" "vpc_cni" {
  count                       = var.enable_eks ? 1 : 0
  cluster_name                = aws_eks_cluster.main[0].name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "coredns" {
  count                       = var.enable_eks ? 1 : 0
  cluster_name                = aws_eks_cluster.main[0].name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "kube_proxy" {
  count                       = var.enable_eks ? 1 : 0
  cluster_name                = aws_eks_cluster.main[0].name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

# Pod Identity agent: without this addon the Pod Identity
# associations below are inert — the driver pods get no IAM
# credentials and the EBS/EFS CSI drivers (and the guard)
# fail with AccessDenied. The associations alone do not
# install the agent; this addon does. It must be installed
# before any pod that relies on Pod Identity starts, so the
# CSI addons depend on it below.
resource "aws_eks_addon" "pod_identity_agent" {
  count                       = var.enable_eks ? 1 : 0
  cluster_name                = aws_eks_cluster.main[0].name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "ebs_csi" {
  count                       = var.enable_eks ? 1 : 0
  cluster_name                = aws_eks_cluster.main[0].name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.main,
    aws_eks_pod_identity_association.ebs_csi,
    aws_eks_addon.pod_identity_agent,
  ]
}

resource "aws_eks_addon" "efs_csi" {
  count                       = var.enable_eks && var.enable_efs ? 1 : 0
  cluster_name                = aws_eks_cluster.main[0].name
  addon_name                  = "aws-efs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.main,
    aws_eks_pod_identity_association.efs_csi,
    aws_eks_addon.pod_identity_agent,
  ]
}

# Optional: CloudWatch observability addon. Off by default;
# kube-prometheus-stack is the primary observability path.
# Verify the service account name in current AWS docs before
# enabling (see variables.tf).
resource "aws_iam_role" "cloudwatch_observability" {
  count = var.enable_eks && var.enable_cloudwatch_observability ? 1 : 0
  name  = "${var.cluster_name}-cloudwatch-observability"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cloudwatch_observability" {
  count      = var.enable_eks && var.enable_cloudwatch_observability ? 1 : 0
  role       = aws_iam_role.cloudwatch_observability[0].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_eks_pod_identity_association" "cloudwatch_observability" {
  count           = var.enable_eks && var.enable_cloudwatch_observability ? 1 : 0
  cluster_name    = aws_eks_cluster.main[0].name
  namespace       = "amazon-cloudwatch"
  service_account = "cloudwatch-agent"
  role_arn        = aws_iam_role.cloudwatch_observability[0].arn
}

resource "aws_eks_addon" "cloudwatch_observability" {
  count                       = var.enable_eks && var.enable_cloudwatch_observability ? 1 : 0
  cluster_name                = aws_eks_cluster.main[0].name
  addon_name                  = "amazon-cloudwatch-observability"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.main,
    aws_eks_pod_identity_association.cloudwatch_observability,
    aws_eks_addon.pod_identity_agent,
  ]
}
