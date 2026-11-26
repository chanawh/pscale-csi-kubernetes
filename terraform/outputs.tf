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

output "eks_kubeconfig_command" {
  description = "Run this after apply to point kubectl at the EKS cluster."
  value       = var.enable_eks ? "aws eks update-kubeconfig --name ${aws_eks_cluster.main[0].name} --region ${var.region}" : ""
}

output "efs_file_system_id" {
  description = "EFS filesystem ID for k8s/eks/storageclass-efs.yaml (scripts/eks/deploy_eks.sh substitutes it). Empty when EFS is off."
  value       = var.enable_eks && var.enable_efs ? aws_efs_file_system.main[0].id : ""
}

output "onefs_host" {
  value = var.onefs_host
}

output "cnpg_wal_bucket" {
  description = "S3 bucket for the CNPG WAL archive (k8s/cnpg/objectstore.yaml). scripts/eks/cnpg_failover_eks.sh reads this with terraform output and substitutes it into the ObjectStore. Empty when EKS is off."
  value       = var.enable_eks ? aws_s3_bucket.cnpg_wal[0].id : ""
}

output "cnpg_wal_bucket_arn" {
  value = var.enable_eks ? aws_s3_bucket.cnpg_wal[0].arn : ""
}

output "cnpg_wal_kms_key_id" {
  value = var.enable_eks ? aws_kms_key.cnpg_wal[0].id : ""
}
