variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "region" {
  description = "AWS region (used to construct service names)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to attach endpoints to"
  type        = string
}

variable "vpc_cidr_block" {
  description = "VPC CIDR block (used in endpoint security group ingress rule)"
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnet IDs for interface endpoint ENIs (use private app subnets)"
  type        = list(string)
}

variable "private_route_table_ids" {
  description = "Route table IDs to attach gateway endpoints to"
  type        = list(string)
  default     = []
}

variable "intra_route_table_ids" {
  description = "Intra (TGW attachment) route table IDs to attach gateway endpoints to"
  type        = list(string)
  default     = []
}

# ---- Endpoint toggles ----

variable "enable_s3" {
  description = "Create S3 Gateway endpoint (free — always recommended)"
  type        = bool
  default     = true
}

variable "enable_dynamodb" {
  description = "Create DynamoDB Gateway endpoint (free)"
  type        = bool
  default     = false
}

variable "enable_ecr_api" {
  description = "Create ECR API Interface endpoint (needed for private container pulls)"
  type        = bool
  default     = true
}

variable "enable_ecr_dkr" {
  description = "Create ECR DKR Interface endpoint (needed for private container pulls)"
  type        = bool
  default     = true
}

variable "enable_ssm" {
  description = "Create SSM, SSM Messages, and EC2 Messages Interface endpoints (enables Session Manager without bastion)"
  type        = bool
  default     = true
}

variable "enable_cloudwatch_logs" {
  description = "Create CloudWatch Logs Interface endpoint (keeps log traffic off internet)"
  type        = bool
  default     = true
}

variable "enable_kms" {
  description = "Create KMS Interface endpoint (for EBS/S3 encryption API calls)"
  type        = bool
  default     = true
}

variable "enable_sts" {
  description = "Create STS Interface endpoint (for Pod Identity / IRSA token requests)"
  type        = bool
  default     = true
}

variable "enable_secretsmanager" {
  description = "Create Secrets Manager Interface endpoint (enable for XDR VPC)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to all endpoint resources"
  type        = map(string)
  default     = {}
}
