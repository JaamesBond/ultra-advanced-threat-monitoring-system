output "tgw_id" {
  description = "ID of the Transit Gateway"
  value       = aws_ec2_transit_gateway.this.id
}

output "tgw_arn" {
  description = "ARN of the Transit Gateway"
  value       = aws_ec2_transit_gateway.this.arn
}

output "shared_rt_id" {
  description = "Route table ID for shared-services VPCs (Control Plane + XDR Infrastructure)"
  value       = aws_ec2_transit_gateway_route_table.shared.id
}

output "spoke_rt_id" {
  description = "Route table ID for spoke VPCs (Production + future spokes)"
  value       = aws_ec2_transit_gateway_route_table.spoke.id
}
