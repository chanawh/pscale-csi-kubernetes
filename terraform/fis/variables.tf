variable "region" {
  description = "AWS region of the EKS cluster."
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "EKS cluster name (tagging only; the experiment targets the node-group ASG)."
  type        = string
  default     = "pscale-csi"
}

variable "nodegroup_asg_name" {
  description = "Auto Scaling Group name of the EKS managed node group the AZ-loss test runs against."
  type        = string
}

variable "test_duration_minutes" {
  description = "How long the simulated AZ outage lasts (SSM document TestDurationInMinutes)."
  type        = number
  default     = 2
}

variable "canary_alarm_name" {
  description = "CloudWatch alarm name used as a stop condition. Empty string means no stop-condition alarm (not recommended for a first run)."
  type        = string
  default     = ""
}

variable "fis_role_name" {
  description = "Name of the IAM role FIS assumes."
  type        = string
  default     = "pscale-csi-fis"
}

variable "automation_role_arn" {
  description = "Role the SSM automation document assumes. Empty string means the FIS role itself (the EKS Workshop setup)."
  type        = string
  default     = ""
}
