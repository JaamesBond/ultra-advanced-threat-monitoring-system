#--------------------------------------------------------------
# Kubernetes + Helm providers — authenticated via EKS cluster
#--------------------------------------------------------------

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

#--------------------------------------------------------------
# Tetragon — eBPF in-kernel enforcer (Layer 1)
#
# Tier 1 autonomous response: SIGKILL in <1μs, zero dependency
# on SOAR/Kafka/network. TracingPolicies define kill rules.
# Runs as DaemonSet on every node.
#--------------------------------------------------------------

resource "helm_release" "tetragon" {
  name             = "tetragon"
  namespace        = "kube-system"
  repository       = "https://helm.cilium.io"
  chart            = "tetragon"
  version          = "1.4.0"
  create_namespace = false

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

#--------------------------------------------------------------
# Falco — container runtime security (Layer 2)
#
# Detection tier: syscall monitoring, rule-based alerting.
# Alerts → Falcosidekick → Vector (collector node group) → MSK.
# Runs as DaemonSet on every node via eBPF driver.
#--------------------------------------------------------------

resource "helm_release" "falco" {
  name             = "falco"
  namespace        = "falco"
  repository       = "https://falcosecurity.github.io/charts"
  chart            = "falco"
  version          = "4.25.2"
  create_namespace = true

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
    value = "environment:bc-xdr\\,cluster:bc-xdr-eks"
  }

  # Tag XDR environment
  set {
    name  = "customRules.bc-xdr-rules\\.yaml"
    value = ""
  }

  depends_on = [module.eks]
}
