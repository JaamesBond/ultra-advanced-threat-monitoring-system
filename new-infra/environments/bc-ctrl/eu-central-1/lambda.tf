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

resource "aws_iam_role_policy" "lambda_quarantine_ec2_policy" {
  name   = "lambda_quarantine_ec2_policy"
  role   = aws_iam_role.lambda_quarantine_ec2_role.id

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