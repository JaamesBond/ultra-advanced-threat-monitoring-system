resource "aws_security_group" "security_tools" {
  name        = "security-tools-sg"
  description = "Brain VPC security tools"
  vpc_id      = module.vpc.vpc_id

  # Allow all from prd for monitoring
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.30.0.0/16"]
  }

  # Allow all from ctrl local
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

resource "aws_instance" "security_tools" {
  ami           = "ami-0a457777ab864ed6f" # Amazon Linux 2023 x86_64
  instance_type = "t3.nano"
  subnet_id     = module.vpc.private_subnet_ids[0]

  vpc_security_group_ids = [aws_security_group.security_tools.id]
  iam_instance_profile   = aws_iam_instance_profile.security_tools.name

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y docker
              systemctl enable --now docker
              EOF

  tags = merge(local.common_tags, { Name = "security-tools-brain" })
}

resource "aws_iam_role" "security_tools" {
  name = "security-tools-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.security_tools.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "security_tools" {
  name = "security-tools-profile"
  role = aws_iam_role.security_tools.name
}

resource "aws_security_group" "github_runner" {
  name        = "github-runner-sg"
  description = "Allow all outbound for GH Runner"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

resource "aws_instance" "github_runner" {
  ami                         = "ami-0a457777ab864ed6f" # Amazon Linux 2023 x86_64
  instance_type               = "t3.small"
  subnet_id                   = module.vpc.public_subnet_ids[0]
  associate_public_ip_address = true

  vpc_security_group_ids = [aws_security_group.github_runner.id]
  iam_instance_profile   = aws_iam_instance_profile.github_runner.name

  user_data = <<-EOT
              #!/bin/bash
              yum update -y
              yum install -y docker git jq
              systemctl enable --now docker

              # GitHub Runner Setup
              mkdir /home/ec2-user/actions-runner && cd /home/ec2-user/actions-runner
              curl -o actions-runner-linux-x64-2.316.1.tar.gz -L https://github.com/actions/runner/releases/download/v2.316.1/actions-runner-linux-x64-2.316.1.tar.gz
              tar xzf ./actions-runner-linux-x64-2.316.1.tar.gz
              chown -R ec2-user:ec2-user /home/ec2-user/actions-runner

              # Get registration token using PAT
              PAT=$(aws secretsmanager get-secret-value --secret-id bc/github/runnerpat --query SecretString --output text --region eu-central-1)
              TOKEN=$(curl -X POST -H "Authorization: token $PAT" -H "Accept: application/vnd.github.v3+json" https://api.github.com/repos/JaamesBond/ultra-advanced-threat-monitoring-system/actions/runners/registration-token | jq -r .token)

              sudo -u ec2-user ./config.sh --url https://github.com/JaamesBond/ultra-advanced-threat-monitoring-system --token $TOKEN --name $(hostname) --unattended --replace
              sudo ./svc.sh install
              sudo ./svc.sh start
              EOT

  tags = merge(local.common_tags, { Name = "github-runner-ctrl" })
}

resource "aws_iam_role" "github_runner" {
  name = "github-runner-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "runner_admin" {
  role       = aws_iam_role.github_runner.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "github_runner" {
  name = "github-runner-profile"
  role = aws_iam_role.github_runner.name
}
