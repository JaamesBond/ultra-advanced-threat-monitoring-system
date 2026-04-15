#--------------------------------------------------------------
# GitHub Actions Runner VM — bc-ctrl
#
# Single t3.large in the public subnet. Handles CI deployments
# for BOTH bc-ctrl (AWS API only) and bc-prd (EKS API via
# VPC peering). Labels: self-hosted,linux,bc-ctrl,bc-prd
#
# Access: SSM Session Manager (no SSH keypair needed)
# Outbound: internet via IGW + public IP (no NAT required)
#--------------------------------------------------------------

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

#--------------------------------------------------------------
# IAM — SSM + Secrets Manager (GitHub PAT) + deploy permissions
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
  name               = "${local.platform_name}-${local.env}-runner-role"
  assume_role_policy = data.aws_iam_policy_document.runner_trust.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "runner_ssm" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "runner_secrets" {
  statement {
    sid     = "ReadRunnerPAT"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      "arn:${data.aws_partition.current.partition}:secretsmanager:${local.region}:${data.aws_caller_identity.current.account_id}:secret:bc/github/runnerpat*",
    ]
  }
}

resource "aws_iam_policy" "runner_secrets" {
  name   = "${local.platform_name}-${local.env}-runner-secrets"
  policy = data.aws_iam_policy_document.runner_secrets.json
}

resource "aws_iam_role_policy_attachment" "runner_secrets" {
  role       = aws_iam_role.runner.name
  policy_arn = aws_iam_policy.runner_secrets.arn
}

resource "aws_iam_instance_profile" "runner" {
  name = "${local.platform_name}-${local.env}-runner-profile"
  role = aws_iam_role.runner.name
}

#--------------------------------------------------------------
# Security Group — outbound HTTPS + DNS only
#--------------------------------------------------------------
resource "aws_security_group" "runner" {
  name        = "${local.platform_name}-${local.env}-runner-sg"
  description = "GitHub Actions runner - outbound only"
  vpc_id      = module.vpc.vpc_id

  egress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS UDP"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS TCP"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.platform_name}-${local.env}-runner-sg" })
}

#--------------------------------------------------------------
# EC2 — runner instance
#--------------------------------------------------------------
resource "aws_instance" "runner" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.large"
  subnet_id                   = module.vpc.public_subnet_ids[0]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.runner.name
  vpc_security_group_ids      = [aws_security_group.runner.id]

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

  user_data = base64encode(templatefile("${path.module}/runner_user_data.sh.tpl", {
    github_owner  = local.github_owner
    github_repo   = local.github_repo
    runner_name   = "${local.platform_name}-${local.env}-runner"
    runner_labels = "self-hosted,linux,bc-ctrl,bc-prd"
    region        = local.region
    secret_name   = "bc/github/runnerpat"
  }))

  user_data_replace_on_change = true

  lifecycle {
    ignore_changes = [ami]
  }

  tags = merge(local.common_tags, { Name = "${local.platform_name}-${local.env}-runner" })
}

output "runner_instance_id" {
  value = aws_instance.runner.id
}
