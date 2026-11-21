variable "region" {
  description = "AWS region for the real EKS cluster. Only used when enable_eks is true."
  type        = string
  default     = "us-west-2"
}

variable "enable_eks" {
  description = "Real AWS only: build an EKS cluster. False by default - EKS costs ~$73/month for the control plane alone, plus nodes, and kind is the $0 lab path."
  type        = bool
  default     = false
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "pscale-csi"
}

variable "cluster_version" {
  description = "EKS Kubernetes version. Matches the kind lab (1.31) so the same manifests run in both places."
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = "EKS worker node instance type."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "EKS worker node desired count. 2, so the node-failure drill has somewhere to reschedule to."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "EKS worker node minimum count."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "EKS worker node maximum count."
  type        = number
  default     = 3
}

variable "enable_efs" {
  description = "Create an EFS filesystem for the EFS CSI driver (ReadWriteMany on AWS). Only used when enable_eks is true. EFS Standard is ~$0.30/GB-month; a 10 GiB lab volume is pennies for one day."
  type        = bool
  default     = true
}

variable "enable_cloudwatch_observability" {
  description = "Install the amazon-cloudwatch-observability EKS addon (CloudWatch agent + Fluent Bit). Off by default: kube-prometheus-stack (helm/observability-values.yaml) is the primary observability path in this project. Verify the addon service account name in current AWS docs before enabling."
  type        = bool
  default     = false
}

variable "onefs_host" {
  description = "OneFS Simulator IP or hostname, as reachable from the Kubernetes nodes."
  type        = string
  default     = "192.168.1.50"
}
