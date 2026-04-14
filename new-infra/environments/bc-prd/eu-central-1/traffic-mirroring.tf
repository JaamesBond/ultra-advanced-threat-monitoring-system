#--------------------------------------------------------------
# bc-prd — VPC Traffic Mirroring → Suricata NIDS
#
# Mirrors all EKS node traffic to the Suricata DaemonSet so
# Suricata sees VPC-level traffic, not just packets on its own
# node (Phase 1 gap documented in k8s/suricata/daemonset.yaml).
#
# Architecture:
#   EKS node ENI (source)
#     │  (VXLAN/UDP:4789 encapsulation)
#     ▼
#   Internal NLB (mirror target)
#     │  (forwards to node port 4789)
#     ▼
#   Suricata DaemonSet pod (hostNetwork:true, eth0 capture)
#     │  (app-layer VXLAN decapsulation)
#     ▼
#   EVE JSON → /var/log/suricata/eve.json → Vector
#
# Limitations:
#   1. Mirror sessions are static (Terraform point-in-time).
#      Nodes added by Auto Scaling after `terraform apply` do
#      NOT automatically get mirror sessions. For dynamic session
#      management, add an EventBridge rule + Lambda that calls
#      CreateTrafficMirrorSession whenever a new instance enters
#      the InService state in the EKS ASG.
#
#   2. Traffic Mirroring is billed per GB mirrored. Monitor costs
#      via Cost Explorer tag Component=suricata-mirror.
#
#   3. Traffic Mirroring is only supported on Nitro instances.
#      m6a.large / m6a.xlarge (used by bc-prd node groups) are
#      Nitro-based — no action needed.
#
#   4. AWS automatically excludes VXLAN traffic (UDP:4789) from
#      mirroring to prevent feedback loops — no exclusion rules
#      needed in the mirror filter.
#
# Dependencies: eks-addons.tf (data.aws_eks_cluster.this, module.vpc)
#--------------------------------------------------------------

#--------------------------------------------------------------
# Discover running EKS node instances
#--------------------------------------------------------------
data "aws_instances" "eks_nodes" {
  filter {
    name   = "tag:eks:cluster-name"
    values = [local.eks_cluster_name]
  }
  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

# Primary ENI (device-index 0) for each node
data "aws_network_interfaces" "eks_primary_enis" {
  filter {
    name   = "attachment.instance-id"
    values = data.aws_instances.eks_nodes.ids
  }
  filter {
    name   = "attachment.device-index"
    values = ["0"]
  }
  filter {
    name   = "status"
    values = ["in-use"]
  }

  depends_on = [data.aws_instances.eks_nodes]
}

#--------------------------------------------------------------
# Traffic Mirror Filter — capture everything
#
# Two rules (one per direction) accepting all protocols and CIDRs.
# AWS automatically prevents VXLAN (UDP:4789) re-mirroring.
#--------------------------------------------------------------
resource "aws_ec2_traffic_mirror_filter" "suricata" {
  description      = "All bc-prd traffic mirrored to Suricata NIDS"
  network_services = ["amazon-dns"]   # also mirror Route53 UDP:53 (DNS tunnel detection)

  tags = merge(local.common_tags, {
    Name      = "${local.platform_name}-${local.env}-suricata-mirror-filter"
    Component = "suricata-mirror"
  })
}

resource "aws_ec2_traffic_mirror_filter_rule" "all_inbound" {
  traffic_mirror_filter_id = aws_ec2_traffic_mirror_filter.suricata.id
  rule_number              = 100
  rule_action              = "accept"
  traffic_direction        = "ingress"
  destination_cidr_block   = "0.0.0.0/0"
  source_cidr_block        = "0.0.0.0/0"
}

resource "aws_ec2_traffic_mirror_filter_rule" "all_outbound" {
  traffic_mirror_filter_id = aws_ec2_traffic_mirror_filter.suricata.id
  rule_number              = 100
  rule_action              = "accept"
  traffic_direction        = "egress"
  destination_cidr_block   = "0.0.0.0/0"
  source_cidr_block        = "0.0.0.0/0"
}

#--------------------------------------------------------------
# Internal NLB — receives VXLAN from mirroring, forwards to nodes
#
# mirror target → NLB → EKS node port 4789
# Suricata pods (hostNetwork: true) receive the VXLAN packets
# on eth0, the app-layer VXLAN parser decapsulates them.
#--------------------------------------------------------------
resource "aws_lb" "suricata_mirror" {
  name                       = "${local.platform_name}-${local.env}-suricata"
  internal                   = true
  load_balancer_type         = "network"
  subnets                    = module.vpc.private_subnet_ids
  enable_deletion_protection = true

  tags = merge(local.common_tags, {
    Name      = "${local.platform_name}-${local.env}-suricata-nlb"
    Component = "suricata-mirror"
  })
}

resource "aws_lb_target_group" "suricata_vxlan" {
  name        = "${local.platform_name}-${local.env}-suricata-vxlan"
  port        = 4789
  protocol    = "UDP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  # NLB UDP target groups require TCP health checks.
  # Kubelet healthz (TCP:10250) is always reachable on EKS nodes
  # and acts as a reasonable proxy for node liveness.
  health_check {
    protocol            = "TCP"
    port                = "10250"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(local.common_tags, {
    Component = "suricata-mirror"
  })
}

resource "aws_lb_listener" "suricata_vxlan" {
  load_balancer_arn = aws_lb.suricata_mirror.arn
  port              = 4789
  protocol          = "UDP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.suricata_vxlan.arn
  }
}

# Register every running EKS node in the target group
resource "aws_lb_target_group_attachment" "suricata_nodes" {
  count = length(data.aws_instances.eks_nodes.ids)

  target_group_arn = aws_lb_target_group.suricata_vxlan.arn
  target_id        = data.aws_instances.eks_nodes.ids[count.index]
  port             = 4789
}

#--------------------------------------------------------------
# Security group rule — allow VXLAN from NLB to EKS nodes
#
# NLB preserves source IP so traffic arrives from node IPs
# within the VPC CIDR. The EKS cluster SG covers all nodes.
#--------------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "vxlan_to_eks_nodes" {
  security_group_id = data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  description       = "VPC Traffic Mirroring VXLAN (UDP:4789) to Suricata DaemonSet"
  cidr_ipv4         = local.vpc_cidr
  from_port         = 4789
  to_port           = 4789
  ip_protocol       = "udp"

  tags = merge(local.common_tags, {
    Component = "suricata-mirror"
  })
}

#--------------------------------------------------------------
# Traffic Mirror Target — points to the NLB
#--------------------------------------------------------------
resource "aws_ec2_traffic_mirror_target" "suricata_nlb" {
  description               = "Suricata NIDS NLB (bc-prd)"
  network_load_balancer_arn = aws_lb.suricata_mirror.arn

  tags = merge(local.common_tags, {
    Name      = "${local.platform_name}-${local.env}-suricata-mirror-target"
    Component = "suricata-mirror"
  })
}

#--------------------------------------------------------------
# Traffic Mirror Sessions — one per EKS node primary ENI
#
# VXLAN VNI 100 is arbitrary; it identifies this mirror session
# group. Suricata does not filter on VNI — all VXLAN on port
# 4789 is decapsulated regardless of VNI.
#
# Session number assignment:
#   session 1 — owned by the Lambda auto-mirror (traffic-mirroring-lambda.tf)
#   session 2 — owned by Terraform (this resource)
#
# Using for_each keyed on ENI ID rather than count avoids index-
# shift conflicts when the node list changes between applies.
# If you need a third session (e.g. mirror to a second tool),
# use session_number = 3 in a separate resource.
#--------------------------------------------------------------
locals {
  suricata_vxlan_vni = 100
}

resource "aws_ec2_traffic_mirror_session" "eks_nodes" {
  for_each = toset(data.aws_network_interfaces.eks_primary_enis.ids)

  description              = "bc-prd ENI ${each.value} → Suricata"
  network_interface_id     = each.value
  traffic_mirror_filter_id = aws_ec2_traffic_mirror_filter.suricata.id
  traffic_mirror_target_id = aws_ec2_traffic_mirror_target.suricata_nlb.id
  session_number           = 2   # Lambda owns session 1; Terraform owns session 2
  virtual_network_id       = local.suricata_vxlan_vni

  tags = merge(local.common_tags, {
    Name      = "${local.platform_name}-${local.env}-suricata-session-${each.value}"
    Component = "suricata-mirror"
  })

  depends_on = [
    aws_ec2_traffic_mirror_target.suricata_nlb,
    aws_lb.suricata_mirror,
  ]
}

#--------------------------------------------------------------
# Outputs
#--------------------------------------------------------------
output "suricata_mirror_nlb_dns" {
  description = "DNS name of the Suricata traffic mirror NLB"
  value       = aws_lb.suricata_mirror.dns_name
}

output "suricata_mirror_filter_id" {
  description = "Traffic Mirror Filter ID"
  value       = aws_ec2_traffic_mirror_filter.suricata.id
}

output "suricata_mirror_target_id" {
  description = "Traffic Mirror Target ID"
  value       = aws_ec2_traffic_mirror_target.suricata_nlb.id
}

output "suricata_mirror_session_count" {
  description = "Number of active Terraform-managed mirror sessions (= running EKS nodes at last apply)"
  value       = length(aws_ec2_traffic_mirror_session.eks_nodes)
}
