# Node-down guard, EKS side: the IAM role the guard's in-cluster
# CronJob (k8s/guard/) assumes through Pod Identity so its AWS
# checker can call EC2.
#
# The guard's second condition is "a second source confirms the
# instance is down". On EKS that source is ec2:DescribeInstances
# on the node's instance (guard/node_guard.py, AwsChecker). Without
# this role the CronJob pod has no AWS credentials, the checker
# returns "unknown", and the guard refuses every time — it never
# taints, so the automation the guard exists to provide does not
# run. The role is DescribeInstances only: the guard never stops,
# terminates, or modifies an instance; it only reads instance
# state and patches the node object (through the Kubernetes RBAC
# in k8s/guard/rbac.yaml, not this role).
#
# Lab-only: DescribeInstances does not support resource-level
# permissions for the instances list call, so it is allowed on
# all resources in this account. Gated by enable_eks, like the
# rest of the EKS path. The service account (node-guard,
# namespace csi-demo) is created by kubectl apply -f k8s/guard/
# (rbac.yaml), not by Terraform; the association references it
# by name, so it works once the guard is applied.
# The pod also needs the AWS CLI binary (python:3.12-slim has
# none); the CronJob installs it at start, see
# k8s/guard/cronjob.yaml.

resource "aws_iam_role" "node_guard" {
  count = var.enable_eks ? 1 : 0
  name  = "${var.cluster_name}-node-guard"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "node_guard_describe" {
  count = var.enable_eks ? 1 : 0
  name  = "${var.cluster_name}-node-guard-describe"
  role  = aws_iam_role.node_guard[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:DescribeInstances"]
      Resource = ["*"]
    }]
  })
}

resource "aws_eks_pod_identity_association" "node_guard" {
  count           = var.enable_eks ? 1 : 0
  cluster_name    = aws_eks_cluster.main[0].name
  namespace       = "csi-demo"
  service_account = "node-guard"
  role_arn        = aws_iam_role.node_guard[0].arn

  depends_on = [aws_eks_addon.pod_identity_agent]
}
