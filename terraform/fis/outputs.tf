output "experiment_template_id" {
  description = "ID of the FIS experiment template. Start it with: aws fis start-experiment --experiment-template-id <id>"
  value       = aws_fis_experiment_template.az_loss.id
}

output "fis_role_arn" {
  description = "IAM role FIS assumes."
  value       = aws_iam_role.fis.arn
}
