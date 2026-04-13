#--------------------------------------------------------------
# Transit Gateway
# - Custom route tables (disable defaults to enforce explicit association)
# - DNS support enabled for cross-VPC name resolution
# - Appliance mode is set per-attachment (in environment vpc.tf), not here
#--------------------------------------------------------------
resource "aws_ec2_transit_gateway" "this" {
  description                     = var.description
  amazon_side_asn                 = var.amazon_side_asn
  auto_accept_shared_attachments  = "disable"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  dns_support                     = "enable"
  multicast_support               = "disable"
  vpn_ecmp_support                = "enable"

  tags = merge(var.tags, { Name = var.name })
}

#--------------------------------------------------------------
# Shared-services route table
# Associated with: Control Plane VPC + XDR Infrastructure VPC
# Both can reach each other and propagate routes to spoke-rt
#--------------------------------------------------------------
resource "aws_ec2_transit_gateway_route_table" "shared" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = merge(var.tags, { Name = "${var.name}-rt-shared" })
}

#--------------------------------------------------------------
# Spoke route table
# Associated with: Production VPC and all future spoke VPCs
# Static 0.0.0.0/0 → XDR attachment is added by the bc-xdr environment
# after the XDR attachment ID is known
#--------------------------------------------------------------
resource "aws_ec2_transit_gateway_route_table" "spoke" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = merge(var.tags, { Name = "${var.name}-rt-spoke" })
}
