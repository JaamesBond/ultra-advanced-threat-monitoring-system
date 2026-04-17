#--------------------------------------------------------------
# Wazuh all-in-one EC2 deployment — bc-ctrl
#
# Single t3.xlarge instance running Manager + Indexer + Dashboard.
# Agents in bc-prd reach wazuh on ports 1514/1515 via VPC peering.
#--------------------------------------------------------------

###############################################################
# Security Group
###############################################################

resource "aws_security_group" "wazuh_ec2" {
  name        = "wazuh-ec2-sg"
  description = "Wazuh EC2 all-in-one - manager, indexer, dashboard"
  vpc_id      = module.vpc.vpc_id

  # Wazuh agent events from bc-prd (via VPC peering)
  ingress {
    description = "Wazuh agent events from bc-prd"
    from_port   = 1514
    to_port     = 1514
    protocol    = "tcp"
    cidr_blocks = [local.prd_vpc_cidr]
  }

  # Wazuh agent enrollment from bc-prd (via VPC peering)
  ingress {
    description = "Wazuh agent enrollment from bc-prd"
    from_port   = 1515
    to_port     = 1515
    protocol    = "tcp"
    cidr_blocks = [local.prd_vpc_cidr]
  }

  # Wazuh agent events from bc-ctrl
  ingress {
    description = "Wazuh agent events from bc-ctrl"
    from_port   = 1514
    to_port     = 1514
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  # Wazuh agent enrollment from bc-ctrl
  ingress {
    description = "Wazuh agent enrollment from bc-ctrl"
    from_port   = 1515
    to_port     = 1515
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  # Wazuh REST API from bc-ctrl
  ingress {
    description = "Wazuh API from bc-ctrl"
    from_port   = 55000
    to_port     = 55000
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  # OpenSearch HTTP from bc-ctrl
  ingress {
    description = "OpenSearch HTTP from bc-ctrl"
    from_port   = 9200
    to_port     = 9200
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  # Wazuh Dashboard HTTPS from bc-ctrl
  ingress {
    description = "Dashboard HTTPS from bc-ctrl"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "wazuh-ec2-sg" })
}

###############################################################
# IAM Role & Instance Profile
###############################################################

resource "aws_iam_role" "wazuh_ec2" {
  name = "wazuh-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = merge(local.common_tags, { Name = "wazuh-ec2-role" })
}

resource "aws_iam_role_policy_attachment" "wazuh_ec2_ssm" {
  role       = aws_iam_role.wazuh_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "wazuh_ec2_inline" {
  name = "wazuh-ec2-inline"
  role = aws_iam_role.wazuh_ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerWazuhMisp"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          "arn:aws:secretsmanager:eu-central-1:286439316079:secret:bc/wazuh/*",
          "arn:aws:secretsmanager:eu-central-1:286439316079:secret:bc/misp*"
        ]
      },
      {
        Sid    = "S3WazuhSnapshotsReadWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::bc-uatms-wazuh-snapshots",
          "arn:aws:s3:::bc-uatms-wazuh-snapshots/*"
        ]
      },
      {
        Sid    = "S3LogBucketsReadOnly"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::bc-cloudtrail-logs",
          "arn:aws:s3:::bc-cloudtrail-logs/*",
          "arn:aws:s3:::bc-guardduty-logs",
          "arn:aws:s3:::bc-guardduty-logs/*",
          "arn:aws:s3:::bc-vpcflow-logs",
          "arn:aws:s3:::bc-vpcflow-logs/*",
          "arn:aws:s3:::bc-config-logs",
          "arn:aws:s3:::bc-config-logs/*"
        ]
      },
      {
        Sid    = "KMSWazuhEBS"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey",
          "kms:CreateGrant"
        ]
        Resource = [aws_kms_key.wazuh_ec2.arn]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "wazuh_ec2" {
  name = "wazuh-ec2-profile"
  role = aws_iam_role.wazuh_ec2.name

  tags = merge(local.common_tags, { Name = "wazuh-ec2-profile" })
}

###############################################################
# KMS CMK — EBS encryption for all Wazuh EC2 volumes
###############################################################

resource "aws_kms_key" "wazuh_ec2" {
  description             = "CMK for Wazuh EC2 EBS volumes"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RootFullAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::286439316079:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "WazuhInstanceRoleUse"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.wazuh_ec2.arn
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey",
          "kms:CreateGrant"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(local.common_tags, { Name = "wazuh-ec2-cmk" })
}

resource "aws_kms_alias" "wazuh_ec2" {
  name          = "alias/wazuh-ec2"
  target_key_id = aws_kms_key.wazuh_ec2.key_id
}

###############################################################
# Install script — uploaded to S3, pulled by user_data on boot
###############################################################

resource "aws_s3_object" "wazuh_install_script" {
  bucket      = "bc-uatms-wazuh-snapshots"
  key         = "scripts/phase3-install-wazuh.sh"
  source      = "${path.module}/../../../scripts/phase3-install-wazuh.sh"
  source_hash = filemd5("${path.module}/../../../scripts/phase3-install-wazuh.sh")
  server_side_encryption = "AES256"
}

###############################################################
# Wazuh all-in-one instance
###############################################################

resource "aws_instance" "wazuh" {
  ami                         = "ami-0a457777ab864ed6f" # Amazon Linux 2023 x86_64 eu-central-1
  instance_type               = "t3.xlarge"
  subnet_id                   = module.vpc.private_subnet_ids[0]
  user_data_replace_on_change = true

  vpc_security_group_ids = [aws_security_group.wazuh_ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.wazuh_ec2.name

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    kms_key_id            = aws_kms_key.wazuh_ec2.arn
    delete_on_termination = true
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    exec > >(tee /var/log/wazuh-install.log | logger -t wazuh-install) 2>&1

    dnf update -y
    dnf install -y unzip jq

    # Install AWS CLI v2
    curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp/awscliv2-extract
    /tmp/awscliv2-extract/aws/install
    rm -rf /tmp/awscliv2.zip /tmp/awscliv2-extract

    # Download and run install script
    aws s3 cp s3://${aws_s3_object.wazuh_install_script.bucket}/${aws_s3_object.wazuh_install_script.key} \
      /tmp/phase3-install-wazuh.sh --region eu-central-1
    chmod +x /tmp/phase3-install-wazuh.sh

    HOST_ROLE=all_in_one bash /tmp/phase3-install-wazuh.sh
  EOF

  tags = merge(local.common_tags, { Name = "wazuh-ctrl" })

  depends_on = [aws_s3_object.wazuh_install_script]
}

resource "aws_ebs_volume" "wazuh_data" {
  availability_zone = local.azs[0] # eu-central-1a — same AZ as private_subnet_ids[0]
  size              = 200
  type              = "gp3"
  iops              = 6000
  throughput        = 250
  encrypted         = true
  kms_key_id        = aws_kms_key.wazuh_ec2.arn

  tags = merge(local.common_tags, { Name = "wazuh-data" })
}

resource "aws_volume_attachment" "wazuh_data" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.wazuh_data.id
  instance_id = aws_instance.wazuh.id
}

###############################################################
# Route53 — private A records in bc-ctrl.internal
# All 3 DNS names point to the single all-in-one instance
###############################################################

resource "aws_route53_record" "wazuh_manager" {
  zone_id = aws_route53_zone.bc_ctrl_internal.zone_id
  name    = "wazuh-manager.bc-ctrl.internal"
  type    = "A"
  ttl     = 60
  records = [aws_instance.wazuh.private_ip]
}

resource "aws_route53_record" "wazuh_indexer" {
  zone_id = aws_route53_zone.bc_ctrl_internal.zone_id
  name    = "wazuh-indexer.bc-ctrl.internal"
  type    = "A"
  ttl     = 60
  records = [aws_instance.wazuh.private_ip]
}

resource "aws_route53_record" "wazuh_dashboard" {
  zone_id = aws_route53_zone.bc_ctrl_internal.zone_id
  name    = "wazuh-dashboard.bc-ctrl.internal"
  type    = "A"
  ttl     = 60
  records = [aws_instance.wazuh.private_ip]
}

###############################################################
# Outputs
###############################################################

output "wazuh_private_ip" {
  description = "Private IP of the Wazuh all-in-one EC2 instance"
  value       = aws_instance.wazuh.private_ip
}
