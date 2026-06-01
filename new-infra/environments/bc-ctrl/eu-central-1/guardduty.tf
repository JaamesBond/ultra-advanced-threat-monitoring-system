#--------------------------------------------------------------
# GuardDuty — bc-ctrl (account 997916278486, eu-central-1)
#
# COST POSTURE (target ~$3-4/mo after 30-day free trial):
#   Enabled base features (included in detector price):
#     - CloudTrail management event analysis
#     - VPC Flow Log analysis
#     - DNS query log analysis
#   Explicitly DISABLED paid add-ons (see aws_guardduty_detector_feature blocks):
#     - RUNTIME_MONITORING      (EKS/EC2 runtime agent — redundant with Falco+Tetragon)
#     - EKS_AUDIT_LOGS          (paid; bc-prd audit log analysis not needed here)
#     - EBS_MALWARE_PROTECTION  (expensive per-GB scan)
#     - RDS_LOGIN_EVENTS        (no RDS in this account)
#     - LAMBDA_NETWORK_LOGS     (no Lambda network flows of interest)
#     - S3_DATA_EVENTS          (we only care about mgmt events, not data-plane S3 calls)
#
# Budget alert:  aws_budgets_budget chosen over Cost Anomaly Detection.
# Rationale: the budget is a hard monthly ceiling across the full account,
# giving an early warning if any resource drifts. Cost Anomaly Detection
# fires on statistical spikes — useful for large accounts but overkill here.
# A $30/mo ceiling with 80%+100% email alerts is simple, zero extra cost,
# and covers GuardDuty creep as well as any other runaway resource.
#
# Wazuh ingestion path:
#   GuardDuty → s3:PutObject → aws_s3_bucket.guardduty_logs (bc-guardduty-logs-*)
#   Wazuh EC2 → s3:GetObject+s3:ListBucket (granted in wazuh-ec2.tf S3LogBucketsReadOnly Sid)
#--------------------------------------------------------------

###############################################################
# GuardDuty Detector
###############################################################

resource "aws_guardduty_detector" "main" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = merge(local.common_tags, { Name = "bc-ctrl-guardduty" })
}

###############################################################
# Feature gates — explicitly DISABLE all paid optional features
#
# aws_guardduty_detector_feature is available in hashicorp/aws
# >= 4.46 (well within the ">= 6.23" constraint in terraform_config.tf).
# Each feature block is independent; omitting one leaves the feature
# at its AWS default (DISABLED for new detectors, but pinning all
# six here makes the cost posture explicit and drift-proof).
#
# ADDITIONAL_CONFIGURATION sub-blocks are only valid for
# RUNTIME_MONITORING (the EKS/EC2 runtime agent toggles). All
# other features have no sub-configuration — do NOT add
# additional_configuration to those blocks.
###############################################################

resource "aws_guardduty_detector_feature" "runtime_monitoring" {
  detector_id = aws_guardduty_detector.main.id
  name        = "RUNTIME_MONITORING"
  status      = "DISABLED"

  # Sub-feature: auto-deploy runtime agent on EKS nodes. Only
  # settable when the parent feature is DISABLED — keep DISABLED.
  additional_configuration {
    name   = "EKS_ADDON_MANAGEMENT"
    status = "DISABLED"
  }

  # Sub-feature: auto-deploy runtime agent on EC2 instances.
  additional_configuration {
    name   = "EC2_AGENT_MANAGEMENT"
    status = "DISABLED"
  }

  # Sub-feature: auto-deploy runtime agent on ECS tasks.
  additional_configuration {
    name   = "ECS_FARGATE_AGENT_MANAGEMENT"
    status = "DISABLED"
  }
}

resource "aws_guardduty_detector_feature" "eks_audit_logs" {
  detector_id = aws_guardduty_detector.main.id
  name        = "EKS_AUDIT_LOGS"
  status      = "DISABLED"
}

resource "aws_guardduty_detector_feature" "ebs_malware_protection" {
  detector_id = aws_guardduty_detector.main.id
  name        = "EBS_MALWARE_PROTECTION"
  status      = "DISABLED"
}

resource "aws_guardduty_detector_feature" "rds_login_events" {
  detector_id = aws_guardduty_detector.main.id
  name        = "RDS_LOGIN_EVENTS"
  status      = "DISABLED"
}

resource "aws_guardduty_detector_feature" "lambda_network_logs" {
  detector_id = aws_guardduty_detector.main.id
  name        = "LAMBDA_NETWORK_LOGS"
  status      = "DISABLED"
}

resource "aws_guardduty_detector_feature" "s3_data_events" {
  detector_id = aws_guardduty_detector.main.id
  name        = "S3_DATA_EVENTS"
  status      = "DISABLED"
}

###############################################################
# KMS CMK — GuardDuty findings encryption
#
# GuardDuty requires a CMK for publishing destinations.
# The key policy grants:
#   1. Root account full admin (standard AWS requirement).
#   2. guardduty.amazonaws.com  GenerateDataKey + Encrypt, scoped
#      to this account (aws:SourceAccount) and this detector ARN
#      (aws:SourceArn) — prevents confused-deputy attacks.
###############################################################

resource "aws_kms_key" "guardduty" {
  description             = "CMK for GuardDuty findings encryption — bc-ctrl"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RootFullAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "GuardDutyEncrypt"
        Effect = "Allow"
        Principal = {
          Service = "guardduty.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Encrypt"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
            "aws:SourceArn"     = "arn:aws:guardduty:${local.region}:${data.aws_caller_identity.current.account_id}:detector/${aws_guardduty_detector.main.id}"
          }
        }
      },
      {
        # Wazuh EC2 role needs Decrypt to read the encrypted findings objects from S3.
        # kms:ViaService restricts the grant to S3 GetObject calls only — the Wazuh
        # role cannot use this key for arbitrary KMS Decrypt operations outside of S3.
        Sid    = "WazuhDecrypt"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.wazuh_ec2.arn
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "s3.${local.region}.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, { Name = "guardduty-cmk" })
}

resource "aws_kms_alias" "guardduty" {
  name          = "alias/guardduty-bc-ctrl"
  target_key_id = aws_kms_key.guardduty.key_id
}

###############################################################
# S3 Bucket Policy — grants GuardDuty write access
#
# The bucket (aws_s3_bucket.guardduty_logs) and its public-access
# block already exist in s3-log-buckets.tf. A service-principal
# bucket policy is fully compatible with block_public_policy=true
# because that setting only blocks ACL-based public access, not
# service-principal statements.
#
# Statements:
#   1. GetBucketLocation — GuardDuty calls this before publishing.
#   2. PutObject         — findings delivery, scoped to bucket-owner-full-control
#                          ACL and this account (prevents cross-account injection).
###############################################################

resource "aws_s3_bucket_policy" "guardduty_logs" {
  bucket = aws_s3_bucket.guardduty_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GuardDutyGetBucketLocation"
        Effect = "Allow"
        Principal = {
          Service = "guardduty.amazonaws.com"
        }
        Action   = "s3:GetBucketLocation"
        Resource = aws_s3_bucket.guardduty_logs.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
            "aws:SourceArn"     = "arn:aws:guardduty:${local.region}:${data.aws_caller_identity.current.account_id}:detector/${aws_guardduty_detector.main.id}"
          }
        }
      },
      {
        Sid    = "GuardDutyPutObject"
        Effect = "Allow"
        Principal = {
          Service = "guardduty.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.guardduty_logs.arn}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"     = "bucket-owner-full-control"
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
            "aws:SourceArn"     = "arn:aws:guardduty:${local.region}:${data.aws_caller_identity.current.account_id}:detector/${aws_guardduty_detector.main.id}"
          }
        }
      }
    ]
  })

  # Public access block must exist before the policy is attached.
  depends_on = [aws_s3_bucket_public_access_block.guardduty_logs]
}

###############################################################
# GuardDuty Publishing Destination — S3
#
# depends_on the bucket policy and KMS key policy so GuardDuty
# can validate write access at creation time (it performs a
# test-write during resource creation; if either policy is
# missing the resource creation fails).
###############################################################

resource "aws_guardduty_publishing_destination" "s3" {
  detector_id      = aws_guardduty_detector.main.id
  destination_type = "S3"
  destination_arn  = aws_s3_bucket.guardduty_logs.arn
  kms_key_arn      = aws_kms_key.guardduty.arn

  depends_on = [
    aws_s3_bucket_policy.guardduty_logs,
    aws_kms_key.guardduty,
  ]
}

###############################################################
# Budget Alert — monthly cost ceiling
#
# Choice: aws_budgets_budget (not Cost Anomaly Detection).
# Rationale in file header above.
#
# $30/mo ceiling covers current baseline (~$3-4 GuardDuty) with
# comfortable headroom. Notifications fire at 80% ($24 actual)
# and 100% ($30 actual) so there is time to react before overage.
# COST type = billed charges (not forecasted), which avoids false
# positives from forecast variance.
###############################################################

resource "aws_budgets_budget" "monthly_ceiling" {
  name         = "bc-ctrl-monthly-ceiling"
  budget_type  = "COST"
  limit_amount = "30"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = ["afonso3marques@gmail.com"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = ["afonso3marques@gmail.com"]
  }

  tags = merge(local.common_tags, { Name = "bc-ctrl-monthly-ceiling" })
}
