output "runner_instance_ids" {
  description = "EC2 instance IDs of the GitHub Actions runners"
  value       = { for k, v in aws_instance.runner : k => v.id }
}

output "runner_private_ips" {
  description = "Private IPs of the GitHub Actions runners"
  value       = { for k, v in aws_instance.runner : k => v.private_ip }
}
