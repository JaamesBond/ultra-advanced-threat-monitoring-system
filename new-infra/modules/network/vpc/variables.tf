variable "vpc_name" {
  description = "Name of the VPC"
  type        = string
}

variable "cidr_block" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "availability_zones" {
  description = "List of availability zones"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (IGW-routed). Pass [] for spoke VPCs with no public access."
  type        = list(string)
  default     = []
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (NAT-routed or TGW-routed)"
  type        = list(string)
}

variable "database_subnet_cidrs" {
  description = "CIDR blocks for isolated data-tier subnets (no default route to internet)"
  type        = list(string)
  default     = []
}

variable "intra_subnet_cidrs" {
  description = "CIDR blocks for TGW attachment subnets (/28 recommended — no internet route)"
  type        = list(string)
  default     = []
}

variable "create_igw" {
  description = "Create an Internet Gateway. Set false for spoke VPCs that have no public subnets."
  type        = bool
  default     = true
}

variable "enable_nat_gateway" {
  description = "Provision NAT Gateways for private subnets. Set false for spoke VPCs routing via TGW."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use a single shared NAT Gateway (dev/cost). Set false for production HA."
  type        = bool
  default     = false
}

variable "one_nat_gateway_per_az" {
  description = "One NAT Gateway per AZ for HA. Recommended for production."
  type        = bool
  default     = true
}

variable "enable_dns_hostnames" {
  description = "Enable DNS hostnames in the VPC"
  type        = bool
  default     = true
}

variable "enable_dns_support" {
  description = "Enable DNS support in the VPC"
  type        = bool
  default     = true
}

variable "enable_flow_log" {
  description = "Enable VPC Flow Logs"
  type        = bool
  default     = true
}

variable "create_flow_log_cloudwatch_log_group" {
  description = "Create a CloudWatch Log Group for flow logs"
  type        = bool
  default     = true
}

variable "create_flow_log_cloudwatch_iam_role" {
  description = "Create an IAM role for flow log delivery"
  type        = bool
  default     = true
}

variable "flow_log_max_aggregation_interval" {
  description = "Max aggregation interval in seconds. Use 60 for XDR/security VPCs, 600 for others."
  type        = number
  default     = 60
}

variable "flow_log_traffic_type" {
  description = "Traffic type to capture: ACCEPT, REJECT, or ALL"
  type        = string
  default     = "ALL"
}

variable "flow_log_retention_in_days" {
  description = "CloudWatch Log Group retention in days"
  type        = number
  default     = 60
}

variable "flow_log_cloudwatch_log_group_name_prefix" {
  description = "Prefix for the CloudWatch Log Group name"
  type        = string
  default     = "/aws/vpc-flow-log/"
}

variable "flow_log_cloudwatch_log_group_kms_key_id" {
  description = "KMS key ARN for flow log encryption at rest"
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
