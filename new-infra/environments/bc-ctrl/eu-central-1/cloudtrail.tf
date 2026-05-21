#--------------------------------------------------------------
# CloudTrail — bc-ctrl
#
# Delivers all management API events to the pre-existing
# bc-cloudtrail-logs S3 bucket so the Wazuh manager's
# aws-s3 wodle can ingest them.
#
# The bucket is NOT managed by this repo (created out-of-band).
# Only the bucket policy and the trail itself are managed here.
# Cost: CloudTrail management events are free for the first
# copy delivered to S3. No additional monthly cost.
#--------------------------------------------------------------

locals {
  cloudtrail_bucket = "bc-cloudtrail-logs"
  cloudtrail_prefix = "AWSLogs/${data.aws_caller_identity.current.account_id}"
}

###############################################################
# S3 Bucket Policy — grants CloudTrail write access
###############################################################

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = local.cloudtrail_bucket

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
        Resource = "arn:aws:s3:::${local.cloudtrail_bucket}"
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
        Resource = "arn:aws:s3:::${local.cloudtrail_bucket}/${local.cloudtrail_prefix}/CloudTrail*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = "arn:aws:cloudtrail:${local.region}:${data.aws_caller_identity.current.account_id}:trail/bc-ctrl-trail"
          }
        }
      }
    ]
  })
}

###############################################################
# CloudTrail Trail
###############################################################

resource "aws_cloudtrail" "bc_ctrl" {
  name                          = "bc-ctrl-trail"
  s3_bucket_name                = local.cloudtrail_bucket
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
