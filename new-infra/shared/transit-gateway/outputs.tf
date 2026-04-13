output "tgw_id" {
  description = "Transit Gateway ID — referenced by all VPC environments via remote_state"
  value       = module.tgw.tgw_id
}

output "tgw_arn" {
  value = module.tgw.tgw_arn
}

output "shared_rt_id" {
  description = "Shared-services route table — associate Control Plane and XDR Infrastructure attachments here"
  value       = module.tgw.shared_rt_id
}

output "spoke_rt_id" {
  description = "Spoke route table — associate Production VPC and future spoke attachments here"
  value       = module.tgw.spoke_rt_id
}
