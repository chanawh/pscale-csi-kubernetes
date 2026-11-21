# EFS: the AWS-native ReadWriteMany counterpart to PowerScale
# NFS in this project. PowerScale CSI gives RWX on OneFS in
# the kind lab; EFS CSI gives RWX on EKS, so the same Postgres
# workload can be compared across block (EBS, RWO), AWS file
# (EFS, RWX), and enterprise file (PowerScale, RWX).
# Gated by enable_eks && enable_efs. Lab only: one mount
# target per default subnet, NFS (2049) open to the VPC CIDR
# only, encrypted at rest, lifecycle to Infrequent Access.

resource "aws_security_group" "efs" {
  count       = var.enable_eks && var.enable_efs ? 1 : 0
  name        = "${var.cluster_name}-efs"
  description = "EFS mount targets: NFS from inside the VPC only (lab)"
  vpc_id      = data.aws_vpc.default[0].id

  ingress {
    description = "NFS from EKS nodes in the VPC"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default[0].cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_efs_file_system" "main" {
  count          = var.enable_eks && var.enable_efs ? 1 : 0
  creation_token = "${var.cluster_name}-efs"
  encrypted      = true

  # Bursting throughput is fine at lab scale and costs nothing
  # beyond storage; provisioned throughput is a production knob.
  throughput_mode = "bursting"

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = {
    Name    = "${var.cluster_name}-efs"
    Project = "pscale-csi-kubernetes"
    Lab     = "one-day-run-destroy-same-day"
  }
}

resource "aws_efs_mount_target" "main" {
  count           = var.enable_eks && var.enable_efs ? length(data.aws_subnets.default[0].ids) : 0
  file_system_id  = aws_efs_file_system.main[0].id
  subnet_id       = data.aws_subnets.default[0].ids[count.index]
  security_groups = [aws_security_group.efs[0].id]
}
