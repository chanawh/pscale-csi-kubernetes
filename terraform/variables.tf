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

variable "onefs_host" {
  description = "OneFS Simulator IP or hostname, as reachable from the Kubernetes nodes."
  type        = string
  default     = "192.168.1.50"
}
