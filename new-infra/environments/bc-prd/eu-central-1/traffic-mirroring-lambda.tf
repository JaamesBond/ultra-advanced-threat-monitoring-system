#--------------------------------------------------------------
# bc-prd — Auto Mirror Lambda
#
# Handles the dynamic mirroring gap documented in traffic-mirroring.tf:
# nodes added by Auto Scaling after `terraform apply` automatically
# receive a Traffic Mirror Session without manual re-apply.
#
# Flow:
#   ASG launches / terminates EKS node
#     → EventBridge rule matches EC2 Instance Launch/Terminate Successful
#     → Lambda invoked
#     → create_session() / delete_session() in auto_mirror.py
#     → Traffic Mirror Session created/deleted on the node's primary ENI
#
# The Lambda also handles idempotency: if Terraform already created
# a session for the ENI (at apply time), it does nothing.
#--------------------------------------------------------------

#--------------------------------------------------------------
# Package the Lambda function
#--------------------------------------------------------------
data "archive_file" "auto_mirror" {
  type        = "zip"
  source_file = "${path.module}/lambda/auto_mirror.py"
  output_path = "${path.module}/lambda/auto_mirror.zip"
}

#--------------------------------------------------------------
# IAM role for the Lambda
#--------------------------------------------------------------
data "aws_iam_policy_document" "auto_mirror_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "auto_mirror_lambda" {
  name               = "${local.platform_name}-${local.env}-auto-mirror-lambda"
  description        = "Lambda role for dynamic VPC Traffic Mirror session management"
  assume_role_policy = data.aws_iam_policy_document.auto_mirror_trust.json

  tags = merge(local.common_tags, { Component = "suricata-mirror" })
}

data "aws_iam_policy_document" "auto_mirror_lambda" {
  # CloudWatch Logs
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${local.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.platform_name}-${local.env}-auto-mirror:*",
    ]
  }

  # EC2: describe instances + ENIs to find new node's primary interface
  statement {
    sid    = "DescribeEC2"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces",
    ]
    resources = ["*"]
  }

  # Traffic Mirroring CRUD — scoped to this account/region
  statement {
    sid    = "TrafficMirror"
    effect = "Allow"
    actions = [
      "ec2:CreateTrafficMirrorSession",
      "ec2:DeleteTrafficMirrorSession",
      "ec2:DescribeTrafficMirrorSessions",
      "ec2:CreateTags",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "auto_mirror_lambda" {
  name        = "${local.platform_name}-${local.env}-auto-mirror-lambda"
  description = "Permissions for the auto-mirror Lambda (Traffic Mirroring + EC2 describe)"
  policy      = data.aws_iam_policy_document.auto_mirror_lambda.json
}

resource "aws_iam_role_policy_attachment" "auto_mirror_lambda" {
  role       = aws_iam_role.auto_mirror_lambda.name
  policy_arn = aws_iam_policy.auto_mirror_lambda.arn
}

#--------------------------------------------------------------
# CloudWatch Log Group — explicit so retention is enforced
#--------------------------------------------------------------
resource "aws_cloudwatch_log_group" "auto_mirror_lambda" {
  name              = "/aws/lambda/${local.platform_name}-${local.env}-auto-mirror"
  retention_in_days = 30

  tags = merge(local.common_tags, { Component = "suricata-mirror" })
}

#--------------------------------------------------------------
# Lambda function
#--------------------------------------------------------------
resource "aws_lambda_function" "auto_mirror" {
  function_name    = "${local.platform_name}-${local.env}-auto-mirror"
  description      = "Creates/deletes VPC Traffic Mirror sessions when EKS nodes join/leave"
  role             = aws_iam_role.auto_mirror_lambda.arn
  runtime          = "python3.12"
  handler          = "auto_mirror.handler"
  filename         = data.archive_file.auto_mirror.output_path
  source_code_hash = data.archive_file.auto_mirror.output_base64sha256
  timeout          = 60    # up to 6 retries × 5s + processing headroom
  memory_size      = 128

  environment {
    variables = {
      MIRROR_FILTER_ID = aws_ec2_traffic_mirror_filter.suricata.id
      MIRROR_TARGET_ID = aws_ec2_traffic_mirror_target.suricata_nlb.id
      EKS_CLUSTER_NAME = local.eks_cluster_name
      VXLAN_VNI        = tostring(local.suricata_vxlan_vni)
      SESSION_NUMBER   = "1"   # unique per ENI; no conflict between nodes
      ENV              = local.env
    }
  }

  tags = merge(local.common_tags, { Component = "suricata-mirror" })

  depends_on = [
    aws_cloudwatch_log_group.auto_mirror_lambda,
    aws_iam_role_policy_attachment.auto_mirror_lambda,
  ]
}

#--------------------------------------------------------------
# EventBridge rule — Auto Scaling launch / terminate events
#
# Matches all ASG events in this account/region. The Lambda
# filters to only act on nodes belonging to local.eks_cluster_name
# by checking the "eks:cluster-name" instance tag.
#--------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "asg_lifecycle" {
  name        = "${local.platform_name}-${local.env}-asg-mirror-lifecycle"
  description = "Triggers auto-mirror Lambda on EKS node launch/terminate"

  event_pattern = jsonencode({
    source      = ["aws.autoscaling"]
    detail-type = [
      "EC2 Instance Launch Successful",
      "EC2 Instance Terminate Successful",
    ]
  })

  tags = merge(local.common_tags, { Component = "suricata-mirror" })
}

resource "aws_cloudwatch_event_target" "auto_mirror_lambda" {
  rule      = aws_cloudwatch_event_rule.asg_lifecycle.name
  target_id = "auto-mirror-lambda"
  arn       = aws_lambda_function.auto_mirror.arn
}

# Allow EventBridge to invoke the Lambda
resource "aws_lambda_permission" "eventbridge_invoke" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auto_mirror.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.asg_lifecycle.arn
}

#--------------------------------------------------------------
# Outputs
#--------------------------------------------------------------
output "auto_mirror_lambda_arn" {
  description = "ARN of the auto-mirror Lambda function"
  value       = aws_lambda_function.auto_mirror.arn
}

output "auto_mirror_lambda_log_group" {
  description = "CloudWatch Log Group for the auto-mirror Lambda"
  value       = aws_cloudwatch_log_group.auto_mirror_lambda.name
}
