resource "helm_release" "cilium" {
  name             = "cilium"
  repository       = "https://helm.cilium.io/"
  chart            = "cilium"
  version          = "1.19.3"
  namespace        = "kube-system"
  cleanup_on_fail  = true

  depends_on = [module.eks]

  set {
    name  = "cni.chainingMode"
    value = "aws-cni"
  }
  set {
    name  = "cni.exclusive"
    value = "false"
  }
  set {
    name  = "enableIPv4Masquerade"
    value = "false"
  }
  set {
    name  = "routingMode"
    value = "native"
  }
  set {
    name  = "hubble.enabled"
    value = "true"
  }
  set {
    name  = "hubble.relay.enabled"
    value = "true"
  }
  set {
    name  = "hubble.ui.enabled"
    value = "false"
  }
  set {
    name  = "policyEnforcementMode"
    value = "default"
  }
}

resource "helm_release" "falco" {
  name             = "falco"
  repository       = "https://falcosecurity.github.io/charts"
  chart            = "falco"
  namespace        = "falco"
  create_namespace = true
  version          = "8.0.2"
  timeout          = 600
  cleanup_on_fail  = true

  depends_on = [module.eks]

  values = [
    file("${path.module}/falco-rules.yaml")
  ]

  set {
    name  = "driver.kind"
    value = "modern_ebpf"
  }
}

resource "helm_release" "tetragon" {
  name            = "tetragon"
  repository      = "https://helm.cilium.io/"
  chart           = "tetragon"
  version         = "1.6.1"
  namespace       = "kube-system"
  cleanup_on_fail = true

  depends_on = [module.eks]
}
