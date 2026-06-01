#--------------------------------------------------------------
# CloudTrail — bc-ctrl
#
# Delivers all management API events to S3 so the Wazuh manager's
# aws-s3 wodle can ingest them. The bucket is now fully managed
# by Terraform with an account-suffixed name for cold-start
# reproducibility.
#
# Cost: CloudTrail management events are free for the first
# copy delivered to S3. No additional monthly cost.
#--------------------------------------------------------------

locals {
  cloudtrail_prefix = "AWSLogs/${data.aws_caller_identity.current.account_id}"
}

###############################################################
# S3 Bucket — CloudTrail log delivery target
###############################################################

resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket        = local.cloudtrail_bucket
  force_destroy = true

  tags = merge(local.common_tags, { Name = local.cloudtrail_bucket })
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_logs" {
  bucket                  = aws_s3_bucket.cloudtrail_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

###############################################################
# S3 Bucket Policy — grants CloudTrail write access
###############################################################

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail_logs.arn
        Condition = {
          StringEquals = {
            "aws:SourceArn" = "arn:aws:cloudtrail:${local.region}:${data.aws_caller_identity.current.account_id}:trail/bc-ctrl-trail"
          }
        }
      },
      {
        Sid    = "CloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail_logs.arn}/${local.cloudtrail_prefix}/CloudTrail*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = "arn:aws:cloudtrail:${local.region}:${data.aws_caller_identity.current.account_id}:trail/bc-ctrl-trail"
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.cloudtrail_logs]
}

###############################################################
# CloudTrail Trail
###############################################################

resource "aws_cloudtrail" "bc_ctrl" {
  name                          = "bc-ctrl-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.id
  s3_key_prefix                 = ""
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  tags = merge(local.common_tags, { Name = "bc-ctrl-trail" })

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}
