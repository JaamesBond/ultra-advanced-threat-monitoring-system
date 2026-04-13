#--------------------------------------------------------------
# bc-ctrl — Wazuh Manager IAM (Pod Identity)
#
# IAM role assumed by the wazuh-manager pods via EKS Pod Identity.
# Grants the Manager the minimum AWS permissions it needs to:
#   - Pull cloud-native log sources (CloudTrail / GuardDuty / VPC
#     Flow Logs / AWS Config) via the wodle aws-s3 integration
#   - Read its own secrets (API creds, cluster key, indexer creds)
#     from Secrets Manager under the bc/wazuh/* prefix
#   - Ship its own alerts / audit to CloudWatch Logs
#   - Describe EC2 resources so geo/owner context can be enriched
#     in alerts (used by active-response + Shuffle lookups)
#
# The actual log buckets are expected to be created by the shared
# logging layer (CloudTrail org trail + GuardDuty + Config). Bucket
# names below match the naming convention used throughout the repo.
#--------------------------------------------------------------

locals {
  wazuh_namespace            = "wazuh"
  wazuh_manager_sa           = "wazuh-manager"
  wazuh_secrets_prefix       = "bc/wazuh"
  wazuh_log_buckets = [
    "bc-cloudtrail-logs",
    "bc-guardduty-findings",
    "bc-vpcflow-logs",
    "bc-config-logs",
  ]
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

#--------------------------------------------------------------
# Trust policy — EKS Pod Identity
#--------------------------------------------------------------
data "aws_iam_policy_document" "wazuh_manager_trust" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]
  }
}

resource "aws_iam_role" "wazuh_manager" {
  name               = "${local.platform_name}-${local.env}-wazuh-manager"
  description        = "Pod Identity role for Wazuh Manager in bc-ctrl EKS"
  assume_role_policy = data.aws_iam_policy_document.wazuh_manager_trust.json

  tags = merge(local.common_tags, {
    Component = "wazuh-manager"
  })
}

#--------------------------------------------------------------
# Permission policy
#--------------------------------------------------------------
data "aws_iam_policy_document" "wazuh_manager" {
  # --- S3: read cloud log sources pulled by wodle aws-s3 ---
  statement {
    sid    = "ReadCloudLogBuckets"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = [
      for b in local.wazuh_log_buckets : "arn:${data.aws_partition.current.partition}:s3:::${b}/*"
    ]
  }

  statement {
    sid    = "ListCloudLogBuckets"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [
      for b in local.wazuh_log_buckets : "arn:${data.aws_partition.current.partition}:s3:::${b}"
    ]
  }

  # --- Secrets Manager: Wazuh cluster key, API creds, indexer creds ---
  statement {
    sid    = "ReadWazuhSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:secretsmanager:${local.region}:${data.aws_caller_identity.current.account_id}:secret:${local.wazuh_secrets_prefix}/*",
    ]
  }

  # --- CloudWatch Logs: ship Manager own logs / audit ---
  statement {
    sid    = "WriteManagerLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${local.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/wazuh/manager/*",
      "arn:${data.aws_partition.current.partition}:logs:${local.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/wazuh/manager/*:log-stream:*",
    ]
  }

  statement {
    sid       = "CreateManagerLogGroups"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup"]
    resources = ["arn:${data.aws_partition.current.partition}:logs:${local.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/wazuh/manager/*"]
  }

  # --- EC2 describe: enrich alerts with instance / VPC context ---
  statement {
    sid    = "DescribeEc2Context"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeVpcs",
      "ec2:DescribeSubnets",
      "ec2:DescribeRegions",
    ]
    resources = ["*"]
  }

  # --- GuardDuty list/get for the integration ---
  statement {
    sid    = "ReadGuardDuty"
    effect = "Allow"
    actions = [
      "guardduty:ListDetectors",
      "guardduty:ListFindings",
      "guardduty:GetFindings",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "wazuh_manager" {
  name        = "${local.platform_name}-${local.env}-wazuh-manager"
  description = "Permissions for Wazuh Manager pods (S3 log ingest, Secrets, CW Logs)"
  policy      = data.aws_iam_policy_document.wazuh_manager.json
}

resource "aws_iam_role_policy_attachment" "wazuh_manager" {
  role       = aws_iam_role.wazuh_manager.name
  policy_arn = aws_iam_policy.wazuh_manager.arn
}

#--------------------------------------------------------------
# Pod Identity association — wires the role to the K8s SA
# namespace/name must match k8s/wazuh/namespace.yaml
#--------------------------------------------------------------
resource "aws_eks_pod_identity_association" "wazuh_manager" {
  cluster_name    = local.eks_cluster_name
  namespace       = local.wazuh_namespace
  service_account = local.wazuh_manager_sa
  role_arn        = aws_iam_role.wazuh_manager.arn

  tags = merge(local.common_tags, {
    Component = "wazuh-manager"
  })
}

#--------------------------------------------------------------
# Outputs
#--------------------------------------------------------------
output "wazuh_manager_role_arn" {
  description = "IAM role ARN assumed by the Wazuh Manager pods via Pod Identity"
  value       = aws_iam_role.wazuh_manager.arn
}
