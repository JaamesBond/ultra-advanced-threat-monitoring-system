output "peering_id" {
  value = var.is_requester ? aws_vpc_peering_connection.this[0].id : var.peering_connection_id
}
