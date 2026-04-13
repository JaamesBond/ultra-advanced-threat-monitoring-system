module "tgw" {
  source = "../../modules/network/transit-gateway"

  name            = "${local.name_prefix}-tgw"
  description     = "Big Chemistry central Transit Gateway - Option A (all VPCs in shared account)"
  amazon_side_asn = 64512
  tags            = local.common_tags
}
