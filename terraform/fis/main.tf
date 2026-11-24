# FIS AZ-loss game day: one experiment template that simulates an
# Availability Zone outage for the EKS node group, using the same
# route the EKS Workshop documents — FIS calls SSM automation
# with the public Resilience Hub document
# AWSResilienceHub-SimulateAzOutageInAsgTest_2020-07-23.
# There is no single built-in FIS "AZ failure" action; this SSM
# document is the named scenario. The DIY alternative (network
# disruption + stop instances, composed by hand) is in
# templates/diy-az-loss.json and docs/FIS_AZ_GAMEDAY.md.
#
# NOT run: this module has never been applied (no AWS account in
# this environment). It is validated (terraform validate) only.
# See docs/FIS_AZ_GAMEDAY.md for the runbook, stop conditions,
# and rollback before running it against a real cluster.
data "aws_caller_identity" "current" {}

locals {
  automation_role_arn = var.automation_role_arn != "" ? var.automation_role_arn : aws_iam_role.fis.arn
  # The SSM document is public; its ARN is region-scoped.
  az_outage_document = "arn:aws:ssm:${var.region}::document/AWSResilienceHub-SimulateAzOutageInAsgTest_2020-07-23"
}

resource "aws_iam_role" "fis" {
  name = var.fis_role_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "fis.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
  tags = { Project = "pscale-csi-kubernetes", Purpose = "fis-az-gameday" }
}

resource "aws_iam_role_policy_attachment" "fis_ec2" {
  role       = aws_iam_role.fis.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSFaultInjectionSimulatorEC2Access"
}

resource "aws_iam_role_policy_attachment" "fis_ssm" {
  role       = aws_iam_role.fis.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSFaultInjectionSimulatorSSMAccess"
}

resource "aws_iam_role_policy_attachment" "fis_network" {
  role       = aws_iam_role.fis.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSFaultInjectionSimulatorNetworkAccess"
}

resource "aws_iam_role_policy" "fis_ssm_automation" {
  name = "fis-ssm-automation"
  role = aws_iam_role.fis.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:StartAutomationExecution"
        Resource = local.az_outage_document
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = local.automation_role_arn
      },
    ]
  })
}

# KMS key for the FIS log group. Lab key: 7-day deletion window.
# The explicit key policy is the AWS default (root account full
# access); CloudWatch Logs accesses the key through grants.
data "aws_iam_policy_document" "fis_logs_key" {
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

resource "aws_kms_key" "fis_logs" {
  description             = "Encrypt FIS experiment logs (lab)"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.fis_logs_key.json
  tags                    = { Project = "pscale-csi-kubernetes" }
}

resource "aws_cloudwatch_log_group" "fis" {
  name              = "/aws/fis/pscale-csi-az-loss"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.fis_logs.arn
  tags              = { Project = "pscale-csi-kubernetes" }
}

resource "aws_fis_experiment_template" "az_loss" {
  description = "Simulate AZ outage for EKS node group ${var.nodegroup_asg_name} (cluster ${var.cluster_name}) via the Resilience Hub SSM document."
  role_arn    = aws_iam_role.fis.arn

  dynamic "stop_condition" {
    for_each = var.canary_alarm_name != "" ? [var.canary_alarm_name] : []
    content {
      source = "aws:cloudwatch:alarm"
      value  = "arn:aws:cloudwatch:${var.region}:${data.aws_caller_identity.current.account_id}:alarm:${stop_condition.value}"
    }
  }

  action {
    name      = "azFailure"
    action_id = "aws:ssm:start-automation-execution"
    parameter {
      key   = "documentArn"
      value = local.az_outage_document
    }
    parameter {
      key = "documentParameters"
      value = jsonencode({
        AutoScalingGroupName  = var.nodegroup_asg_name
        CanaryAlarmName       = var.canary_alarm_name
        AutomationAssumeRole  = local.automation_role_arn
        IsRollback            = "false"
        TestDurationInMinutes = tostring(var.test_duration_minutes)
      })
    }
  }

  log_configuration {
    log_schema_version = "1"
    cloudwatch_logs_configuration {
      log_group_arn = aws_cloudwatch_log_group.fis.arn
    }
  }

  tags = { Project = "pscale-csi-kubernetes", Purpose = "fis-az-gameday" }
}
