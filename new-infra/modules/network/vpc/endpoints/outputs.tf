output "endpoint_sg_id" {
  description = "Security group ID shared by all interface endpoints"
  value       = aws_security_group.endpoints.id
}

output "s3_endpoint_id" {
  description = "S3 Gateway endpoint ID"
  value       = try(aws_vpc_endpoint.s3[0].id, null)
}

output "dynamodb_endpoint_id" {
  description = "DynamoDB Gateway endpoint ID"
  value       = try(aws_vpc_endpoint.dynamodb[0].id, null)
}

output "interface_endpoint_ids" {
  description = "Map of interface endpoint IDs keyed by service name"
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}
