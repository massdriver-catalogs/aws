locals {
  name = var.md_metadata.name_prefix
  port = 51820

  public_subnets = [for s in var.network.subnets : s if s.tier == "public"]

  tunnel_prefix  = split("/", var.tunnel_cidr)[1]
  server_address = "${cidrhost(var.tunnel_cidr, 1)}/${local.tunnel_prefix}"
  client_address = "${cidrhost(var.tunnel_cidr, 2)}/32"

  # The Amazon resolver answers only from inside the VPC, so the laptop asks it
  # through the tunnel to resolve private hostnames like RDS endpoints.
  vpc_resolver = cidrhost(var.network.cidr, 2)
}

data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_partition" "current" {}

resource "wireguard_asymmetric_key" "server" {}
resource "wireguard_asymmetric_key" "client" {}

resource "random_bytes" "preshared_key" {
  length = 32
}

# User data is readable by anyone who can describe the instance, so the
# server's private key waits in Parameter Store for the instance to fetch.
resource "aws_ssm_parameter" "server_private_key" {
  name        = "/${local.name}/wireguard/server-private-key"
  description = "WireGuard private key of ${local.name}"
  type        = "SecureString"
  value       = wireguard_asymmetric_key.server.private_key
}

resource "aws_ssm_parameter" "preshared_key" {
  name        = "/${local.name}/wireguard/preshared-key"
  description = "WireGuard preshared key of ${local.name}"
  type        = "SecureString"
  value       = random_bytes.preshared_key.base64
}

resource "aws_iam_role" "server" {
  name = local.name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "read_keys" {
  name = "read-wireguard-keys"
  role = aws_iam_role.server.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ssm:GetParameter"
      Resource = [aws_ssm_parameter.server_private_key.arn, aws_ssm_parameter.preshared_key.arn]
    }]
  })
}

# Session Manager instead of SSH, so whoever debugs the server needs AWS
# access rather than a key pair and an open port 22.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.server.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "server" {
  name = local.name
  role = aws_iam_role.server.name
}

resource "aws_security_group" "server" {
  name        = local.name
  description = "WireGuard server ${local.name}"
  vpc_id      = var.network.id
}

resource "aws_vpc_security_group_ingress_rule" "wireguard" {
  for_each = toset(var.allowed_source_cidrs)

  security_group_id = aws_security_group.server.id
  description       = "WireGuard from ${each.value}"
  cidr_ipv4         = each.value
  ip_protocol       = "udp"
  from_port         = local.port
  to_port           = local.port
}

# Developer traffic leaves the server toward anything in the VPC.
resource "aws_vpc_security_group_egress_rule" "vpc" {
  security_group_id = aws_security_group.server.id
  description       = "Forwarded developer traffic"
  cidr_ipv4         = var.network.cidr
  ip_protocol       = "-1"
}

# Package installs and Session Manager are HTTPS only.
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.server.id
  description       = "Packages and Session Manager"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_network_interface" "server" {
  subnet_id       = local.public_subnets[0].id
  security_groups = [aws_security_group.server.id]

  lifecycle {
    precondition {
      condition     = length(local.public_subnets) > 0
      error_message = "The VPN server needs a public subnet in the VPC."
    }
  }
}

# The address is attached before the instance boots so it can install
# WireGuard, and it survives a server replacement so the laptop's config
# keeps working.
resource "aws_eip" "server" {
  domain            = "vpc"
  network_interface = aws_network_interface.server.id
}

resource "aws_instance" "server" {
  ami                  = data.aws_ssm_parameter.ami.insecure_value
  instance_type        = var.instance_type
  iam_instance_profile = aws_iam_instance_profile.server.name
  monitoring           = false
  ebs_optimized        = true

  primary_network_interface {
    network_interface_id = aws_network_interface.server.id
  }

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    encrypted = true
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/server.sh.tftpl", {
    region              = var.network.region
    private_key_param   = aws_ssm_parameter.server_private_key.name
    preshared_key_param = aws_ssm_parameter.preshared_key.name
    server_address      = local.server_address
    port                = local.port
    client_public_key   = wireguard_asymmetric_key.client.public_key
    client_address      = local.client_address
  })

  tags = { Name = local.name }

  # A newer AMI would replace the server and drop the developer's session;
  # it picks up the latest one when something else forces a replacement.
  lifecycle {
    ignore_changes = [ami]
  }

  depends_on = [aws_eip.server, aws_iam_role_policy.read_keys]
}
