data "aws_subnet" "private" {
  for_each = toset(var.cluster.network.private_subnet_ids)

  id = each.value
}

locals {
  # EFS allows one mount target in each Availability Zone.
  mount_subnets = {
    for az, ids in { for id, s in data.aws_subnet.private : s.availability_zone => id... } : az => sort(ids)[0]
  }
}

resource "aws_efs_file_system" "home" {
  encrypted  = true
  kms_key_id = aws_kms_key.main.arn

  # Untouched files move to the cheaper class; reading one moves it back.
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }
  lifecycle_policy {
    transition_to_primary_storage_class = "AFTER_1_ACCESS"
  }

  tags = {
    Name = "${local.name}-home"
  }
}

resource "aws_efs_backup_policy" "home" {
  file_system_id = aws_efs_file_system.home.id

  backup_policy {
    status = var.home_backups ? "ENABLED" : "DISABLED"
  }
}

resource "aws_security_group" "efs" {
  name_prefix = "${trimsuffix(substr(local.name, 0, 40), "-")}-efs-"
  description = "Home directory of ${local.name}"
  vpc_id      = var.cluster.network.id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "efs_from_task" {
  security_group_id            = aws_security_group.efs.id
  description                  = "NFS from the workspace"
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
  referenced_security_group_id = aws_security_group.task.id
}

resource "aws_efs_mount_target" "home" {
  for_each = local.mount_subnets

  file_system_id  = aws_efs_file_system.home.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

# The access point makes every file the developer's, whatever user wrote it,
# so a root ECS Exec session can't leave files the developer can't edit.
resource "aws_efs_access_point" "home" {
  file_system_id = aws_efs_file_system.home.id

  posix_user {
    uid = 10001
    gid = 10001
  }

  root_directory {
    path = "/dev"
    creation_info {
      owner_uid   = 10001
      owner_gid   = 10001
      permissions = "0750"
    }
  }

  tags = {
    Name = "${local.name}-home"
  }
}
