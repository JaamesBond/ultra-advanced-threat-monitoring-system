variable "name" {
  description = "Name tag for the Transit Gateway"
  type        = string
}

variable "description" {
  description = "Human-readable description"
  type        = string
  default     = ""
}

variable "amazon_side_asn" {
  description = "Private BGP ASN for the TGW. Must be in 64512-65534 or 4200000000-4294967294."
  type        = number
  default     = 64512
}

variable "tags" {
  description = "Tags applied to all TGW resources"
  type        = map(string)
  default     = {}
}
