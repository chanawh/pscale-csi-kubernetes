output "eks_enabled" {
  description = "True only when enable_eks was set. False on every kind / lab run."
  value       = var.enable_eks
}

output "eks_cluster_name" {
  value = var.enable_eks ? aws_eks_cluster.main[0].name : ""
}

output "eks_cluster_endpoint" {
  value = var.enable_eks ? aws_eks_cluster.main[0].endpoint : ""
}

output "onefs_host" {
  value = var.onefs_host
}
