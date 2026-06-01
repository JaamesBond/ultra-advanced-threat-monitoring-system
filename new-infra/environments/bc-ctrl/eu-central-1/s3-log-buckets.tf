#--------------------------------------------------------------
# S3 Log Buckets — GuardDuty and AWS Config delivery targets
#
# Both buckets use account-suffixed names for cold-start
# reproducibility. GuardDuty and AWS Config S3 delivery are
# NOT yet configured in this repo (no aws_guardduty_publishing_destination
# or aws_config_delivery_channel resource exists), so these
# buckets will be empty until that wiring is added — an existing
# gap, not introduced here. Wazuh has read-only access to both
# via the wazuh-ec2 IAM inline policy in wazuh-ec2.tf.
#--------------------------------------------------------------

###############################################################
# GuardDuty Logs
###############################################################

resource "aws_s3_bucket" "guardduty_logs" {
  bucket        = local.guardduty_bucket
  force_destroy = true

  tags = merge(local.common_tags, { Name = local.guardduty_bucket })
}

resource "aws_s3_bucket_public_access_block" "guardduty_logs" {
  bucket                  = aws_s3_bucket.guardduty_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

###############################################################
# AWS Config Logs
###############################################################

resource "aws_s3_bucket" "config_logs" {
  bucket        = local.config_bucket
  force_destroy = true

  tags = merge(local.common_tags, { Name = local.config_bucket })
}

resource "aws_s3_bucket_public_access_block" "config_logs" {
  bucket                  = aws_s3_bucket.config_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
