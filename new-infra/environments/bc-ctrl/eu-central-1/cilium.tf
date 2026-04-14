#--------------------------------------------------------------
# Cilium CNI — aws-cni chaining mode (bc-ctrl)
#
# vpc-cni continues to own IPAM: pods keep real VPC IPs from the
# 10.0.10-12.0/24 private subnets. Cilium chains after vpc-cni
# and attaches eBPF programs to each pod's veth pair to enforce
# CiliumClusterwideNetworkPolicies and expose Hubble flow data.
#
# Key invariants:
#   cni.chainingMode=aws-cni  — Cilium is a meta-plugin, not sole CNI
#   cni.exclusive=false       — vpc-cni conflist stays intact
#   routingMode=native        — AWS VPC routing; no VXLAN/Geneve tunnels
#   bpf.masquerade=false      — vpc-cni handles SNAT; Cilium must not
#   ipam.mode=cluster-pool    — Cilium tracks pod identities; vpc-cni allocates IPs
#   kubeProxyReplacement=false — kube-proxy still runs; not replaced
#
# Hubble relay gives real-time L3-L7 flow visibility per pod identity.
#
# Images: all pulled through ECR quay/ pull-through cache so the
# pattern is consistent with bc-prd (which has no direct internet path).
# data.aws_caller_identity.current is declared in wazuh-iam.tf.
#
# Gated by local.deploy_cilium_helm. Apply from bastion or a runner
# inside the VPC — CI cannot reach the private EKS endpoint.
#
# ⚠ After apply: rolling-restart all non-kube-system pods so Cilium
#   eBPF programs attach. Apply cilium-policies.tf ONLY after restart.
#--------------------------------------------------------------

resource "helm_release" "cilium" {
  count = local.deploy_cilium_helm ? 1 : 0

  name             = "cilium"
  namespace        = "kube-system"
  repository       = "https://helm.cilium.io"
  chart            = "cilium"
  version          = "1.16.6"
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  timeout          = 600

  # ---- CNI chaining -----------------------------------------------
  set {
    name  = "cni.chainingMode"
    value = "aws-cni"
  }
  set {
    name  = "cni.exclusive"
    value = "false"
  }

  # ---- Routing / dataplane ----------------------------------------
  set {
    name  = "routingMode"
    value = "native"
  }
  set {
    name  = "bpf.masquerade"
    value = "false"
  }

  # ---- IPAM -------------------------------------------------------
  set {
    name  = "ipam.mode"
    value = "cluster-pool"
  }

  # ---- kube-proxy stays -------------------------------------------
  set {
    name  = "kubeProxyReplacement"
    value = "false"
  }

  # ---- Operator ---------------------------------------------------
  set {
    name  = "operator.replicas"
    value = "2"
  }
  set {
    name  = "operator.nodeSelector.role"
    value = "platform"
  }

  # ---- Hubble observability ---------------------------------------
  set {
    name  = "hubble.enabled"
    value = "true"
  }
  set {
    name  = "hubble.relay.enabled"
    value = "true"
  }
  set {
    name  = "hubble.metrics.enabled"
    value = "{dns,http,tcp,drop,flow}"
  }

  # ---- Cluster identity -------------------------------------------
  set {
    name  = "cluster.name"
    value = local.eks_cluster_name
  }

  # ---- Images: ECR pull-through (quay/ prefix) --------------------
  # Main DaemonSet
  set {
    name  = "image.repository"
    value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com/quay/cilium/cilium"
  }
  set {
    name  = "image.tag"
    value = "v1.16.6"
  }
  set {
    name  = "image.useDigest"
    value = "false"
  }

  # Operator (cluster-pool IPAM → operator-generic, not operator-aws)
  set {
    name  = "operator.image.repository"
    value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com/quay/cilium/operator-generic"
  }
  set {
    name  = "operator.image.tag"
    value = "v1.16.6"
  }
  set {
    name  = "operator.image.useDigest"
    value = "false"
  }

  # Hubble relay
  set {
    name  = "hubble.relay.image.repository"
    value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com/quay/cilium/hubble-relay"
  }
  set {
    name  = "hubble.relay.image.tag"
    value = "v1.16.6"
  }
  set {
    name  = "hubble.relay.image.useDigest"
    value = "false"
  }

  # Hubble UI (optional — port-forward to access)
  set {
    name  = "hubble.ui.enabled"
    value = "true"
  }
  set {
    name  = "hubble.ui.frontend.image.repository"
    value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com/quay/cilium/hubble-ui"
  }
  set {
    name  = "hubble.ui.frontend.image.tag"
    value = "v0.13.1"
  }
  set {
    name  = "hubble.ui.backend.image.repository"
    value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com/quay/cilium/hubble-ui-backend"
  }
  set {
    name  = "hubble.ui.backend.image.tag"
    value = "v0.13.1"
  }

  # certgen (used by Hubble relay TLS bootstrap)
  set {
    name  = "certgen.image.repository"
    value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com/quay/cilium/certgen"
  }
  set {
    name  = "certgen.image.tag"
    value = "v0.1.12"
  }
  set {
    name  = "certgen.image.useDigest"
    value = "false"
  }

  depends_on = [module.eks]
}
