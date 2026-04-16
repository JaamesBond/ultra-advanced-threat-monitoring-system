resource "aws_vpc_peering_connection" "this" {
  count       = var.is_requester ? 1 : 0
  vpc_id      = var.vpc_id
  peer_vpc_id = var.peer_vpc_id
  auto_accept = var.auto_accept

  tags = merge(var.tags, { Name = var.peering_name })
}

resource "aws_vpc_peering_connection_accepter" "this" {
  count                     = var.is_requester ? 0 : 1
  vpc_peering_connection_id = var.peering_connection_id
  auto_accept               = true

  tags = merge(var.tags, { Name = var.peering_name })
}

# Routes in local VPC to reach Peer VPC
resource "aws_route" "to_peer" {
  count                     = length(var.route_table_ids)
  route_table_id            = var.route_table_ids[count.index]
  destination_cidr_block    = var.peer_cidr_block
  vpc_peering_connection_id = var.is_requester ? aws_vpc_peering_connection.this[0].id : var.peering_connection_id
}
