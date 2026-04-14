#--------------------------------------------------------------
# Self-hosted GitHub Actions runners — bc-ctrl + bc-prd
#
# Deploys one EC2 instance per VPC in a private subnet.
# Each runner can reach its VPC's EKS private endpoint natively.
# Outbound to GitHub via NAT gateway. SSM for shell access.
#
# Prerequisites:
#   1. Store a GitHub PAT (repo scope) in Secrets Manager:
#      aws secretsmanager create-secret \
#        --name bc/github/runner-pat \
#        --secret-string "ghp_..." \
#        --region eu-central-1
#
#   2. Deploy ctrl + prd VPCs first (this reads their remote state).
#
# Pure AWS API — deploys from CI on ubuntu-latest, no K8s access needed.
#--------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

#--------------------------------------------------------------
# Remote state — read VPC + subnet IDs from each environment
#--------------------------------------------------------------
data "terraform_remote_state" "env" {
  for_each = local.runners

  backend = "s3"
  config = {
    bucket = "bc-uatms-terraform-state"
    key    = each.value.vpc_state_key
    region = local.region
  }
}

#--------------------------------------------------------------
# IAM Role — SSM access + Secrets Manager read for GitHub PAT
#--------------------------------------------------------------
data "aws_iam_policy_document" "runner_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "runner" {
  name               = "${local.name_prefix}-role"
  assume_role_policy = data.aws_iam_policy_document.runner_trust.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "runner_secrets" {
  statement {
    sid     = "ReadRunnerPAT"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      "arn:${data.aws_partition.current.partition}:secretsmanager:${local.region}:${data.aws_caller_identity.current.account_id}:secret:bc/github/runner-pat*",
    ]
  }
}

resource "aws_iam_policy" "runner_secrets" {
  name   = "${local.name_prefix}-secrets"
  policy = data.aws_iam_policy_document.runner_secrets.json
}

resource "aws_iam_role_policy_attachment" "runner_secrets" {
  role       = aws_iam_role.runner.name
  policy_arn = aws_iam_policy.runner_secrets.arn
}

resource "aws_iam_instance_profile" "runner" {
  name = "${local.name_prefix}-profile"
  role = aws_iam_role.runner.name
  tags = local.common_tags
}

#--------------------------------------------------------------
# Security Group — one per VPC (outbound HTTPS only, no inbound)
#--------------------------------------------------------------
resource "aws_security_group" "runner" {
  for_each = local.runners

  name        = "${local.name_prefix}-${each.key}-sg"
  description = "GitHub Actions runner - outbound HTTPS only"
  vpc_id      = data.terraform_remote_state.env[each.key].outputs.vpc_id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-${each.key}-sg"
  })
}

resource "aws_vpc_security_group_egress_rule" "runner_https" {
  for_each = local.runners

  security_group_id = aws_security_group.runner[each.key].id
  description       = "HTTPS to GitHub, ECR, AWS APIs"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# DNS resolution
resource "aws_vpc_security_group_egress_rule" "runner_dns_udp" {
  for_each = local.runners

  security_group_id = aws_security_group.runner[each.key].id
  description       = "DNS (UDP)"
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "runner_dns_tcp" {
  for_each = local.runners

  security_group_id = aws_security_group.runner[each.key].id
  description       = "DNS (TCP)"
  ip_protocol       = "tcp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = "0.0.0.0/0"
}

#--------------------------------------------------------------
# AMI — latest Amazon Linux 2023
#--------------------------------------------------------------
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

#--------------------------------------------------------------
# EC2 Instances — one runner per VPC
#--------------------------------------------------------------
resource "aws_instance" "runner" {
  for_each = local.runners

  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.small"
  iam_instance_profile   = aws_iam_instance_profile.runner.name
  subnet_id              = data.terraform_remote_state.env[each.key].outputs.private_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.runner[each.key].id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    github_owner = local.github_owner
    github_repo  = local.github_repo
    runner_name  = "${local.name_prefix}-${each.key}"
    runner_labels = each.value.labels
    region       = local.region
    secret_name  = "bc/github/runner-pat"
  }))

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-${each.key}"
  })

  lifecycle {
    ignore_changes = [ami]
  }
}
