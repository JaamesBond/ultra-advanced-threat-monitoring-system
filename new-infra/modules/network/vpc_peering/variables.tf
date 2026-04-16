variable "is_requester" {
  type    = bool
  default = true
}

variable "vpc_id" {
  type    = string
  default = ""
}

variable "peer_vpc_id" {
  type    = string
  default = ""
}

variable "auto_accept" {
  type    = bool
  default = true
}

variable "peering_name" {
  type = string
}

variable "peering_connection_id" {
  type    = string
  default = ""
}

variable "route_table_ids" {
  type = list(string)
}

variable "peer_cidr_block" {
  type = string
}

variable "tags" {
  type = map(string)
}
