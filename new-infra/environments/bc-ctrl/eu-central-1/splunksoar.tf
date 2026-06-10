# STATUS (reconciled 2026-06-10, Op-4 control-plane red-team): these resources are
# LIVE and APPLIED — splunk-soar-ec2 (t3.xlarge) is RUNNING and TF-managed, NOT
# commented out. The box runs Splunk SOAR 8.5.0.248 (UI on nginx:8443, SSM-only,
# no inbound SG). It IS wired to Wazuh (929 ingested containers, all label=wazuh_alert)
# but is a PASSIVE SINK: 0 assets, 0 active playbooks, 0 playbook_runs, 0 app_runs ever —
# collects alerts, runs no automation (GAP-006 made concrete). Both Shuffle (integratord
# hook) and Splunk SOAR (custom-splunk-soar.py) receive Wazuh alerts. Admin console opens
# with default/weak creds (soar_local_admin). The instance role (splunk-soar-ec2-role) carries
# lambda:InvokeFunction/InvokeAsync on Resource:* (see finding F-14). Cost note:
# t3.xlarge is the most expensive standing box here — stop/right-size if not in use.

resource "aws_instance" "splunk_soar_ec2" {
  ami                         = "ami-06b79627160ae70a8"
  instance_type               = "t3.xlarge"
  subnet_id                   = module.vpc.private_subnet_ids[0]
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.splunk_soar_ec2_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.splunk_soar_ec2.name

  root_block_device {
    volume_size           = 100
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(local.common_tags, { Name = "splunk-soar-ec2" })
}

resource "aws_security_group" "splunk_soar_ec2_sg" {
  name        = "splunk-soar-ec2-sg"
  description = "Splunk SOAR EC2 security group"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allow SOAR Web UI access"
    from_port   = 8443
    to_port     = 8443
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

  tags = merge(local.common_tags, { Name = "splunk-soar-ec2-sg" })
}

resource "aws_iam_role" "splunk_soar_ec2" {
  name = "splunk-soar-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = merge(local.common_tags, { Name = "splunk-soar-ec2-role" })
}

resource "aws_iam_role_policy_attachment" "splunk_soar_ec2_ssm" {
  role       = aws_iam_role.splunk_soar_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy" "splunk_soar_lambda_policy" {
  name        = "splunk-soar-lambda-policy"
  description = "Policy allowing Splunk SOAR to list and invoke Lambda functions"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "lambda:ListFunctions",
          "lambda:GetFunction",
          "lambda:InvokeFunction",
          "lambda:InvokeAsync",
          "lambda:ListTags",
          "lambda:ListVersionsByFunction",
          "lambda:ListAliases",
          "lambda:ListLayerVersions",
          "lambda:GetPolicy"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(local.common_tags, { Name = "splunk-soar-lambda-policy" })
}

resource "aws_iam_role_policy_attachment" "splunk_soar_lambda_attach" {
  role       = aws_iam_role.splunk_soar_ec2.name
  policy_arn = aws_iam_policy.splunk_soar_lambda_policy.arn
}

resource "aws_iam_instance_profile" "splunk_soar_ec2" {
  name = "splunk-soar-ec2-profile"
  role = aws_iam_role.splunk_soar_ec2.name

  tags = merge(local.common_tags, { Name = "splunk-soar-ec2-profile" })
}

resource "aws_route53_record" "splunk_soar_dns_record" {
  zone_id = aws_route53_zone.bc_ctrl_internal.zone_id
  name    = "splunk-soar.bc-ctrl.internal"
  type    = "A"
  ttl     = 60
  records = [aws_instance.splunk_soar_ec2.private_ip]

  depends_on = [ aws_instance.splunk_soar_ec2 ]
}