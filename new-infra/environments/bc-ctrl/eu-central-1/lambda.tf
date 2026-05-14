resource "aws_security_group" "quarantine_ec2_sg" {
  name        = "quarantine-sg"
  description = "Isolates compromised EC2 instances by denying all inbound and outbound traffic"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = []
  }
}

resource "aws_iam_role" "lambda_quarantine_ec2_role" {
  name = "lambda_quarantine_ec2_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_policy" "lambda_quarantine_ec2_policy" {
  name   = "lambda_quarantine_ec2_policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeSecurityGroups",
          "ec2:ModifyInstanceAttribute"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_quarantine_ec2_attach" {
  role       = aws_iam_role.lambda_quarantine_ec2_role.name
  policy_arn = aws_iam_policy.lambda_quarantine_ec2_policy.arn
}

resource "aws_security_group" "cheap_test_ec2_sg" {
  name        = "cheap-test-ec2-sg"
  description = "Temporary test SG with basic random rules"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "cheap_test_ubuntu" {
  ami                         = data.aws_ami.ubuntu-2404.id
  instance_type               = "t3.nano"
  subnet_id                   = module.vpc.public_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.cheap_test_ec2_sg.id]
  associate_public_ip_address = false

  tags = {
    Name = "cheap-test-ubuntu-soar-test"
  }
}

