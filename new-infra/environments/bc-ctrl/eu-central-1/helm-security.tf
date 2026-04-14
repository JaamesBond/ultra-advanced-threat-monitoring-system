#--------------------------------------------------------------
# Tetragon + Falco — eBPF security enforcement (bc-ctrl)
#
# Tetragon (Layer 1): in-kernel SIGKILL enforcer via TracingPolicies.
#   Autonomous response in <1us, zero dependency on SOAR/Kafka/network.
#   Runs as DaemonSet on every node.
#
# Falco (Layer 2): syscall-level detection + alerting via eBPF driver.
#   Alerts -> Falcosidekick -> Vector -> MSK.
#   Runs as DaemonSet on every node.
#
# Gated by local.deploy_security_helm — requires private endpoint
# connectivity. Set to true when applying from bastion/runner in VPC.
#--------------------------------------------------------------

resource "helm_release" "tetragon" {
  count = local.deploy_security_helm ? 1 : 0

  name             = "tetragon"
  namespace        = "kube-system"
  repository       = "https://helm.cilium.io"
  chart            = "tetragon"
  version          = "1.4.0"
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  timeout          = 600

  set {
    name  = "tetragon.grpc.address"
    value = "localhost:54321"
  }

  # Export events to stdout for Vector/Fluent Bit collection
  set {
    name  = "export.stdout.enabledCommand"
    value = "true"
  }

  depends_on = [module.eks]
}

resource "helm_release" "falco" {
  count = local.deploy_security_helm ? 1 : 0

  name             = "falco"
  namespace        = "falco"
  repository       = "https://falcosecurity.github.io/charts"
  chart            = "falco"
  version          = "4.25.2"
  create_namespace = true
  atomic           = true
  cleanup_on_fail  = true
  timeout          = 600

  # eBPF driver — no kernel module needed
  set {
    name  = "driver.kind"
    value = "ebpf"
  }

  # Falcosidekick for alert routing
  set {
    name  = "falcosidekick.enabled"
    value = "true"
  }

  set {
    name  = "falcosidekick.config.customfields"
    value = "environment:bc-ctrl\\,cluster:bc-ctrl-eks"
  }

  depends_on = [module.eks]
}
