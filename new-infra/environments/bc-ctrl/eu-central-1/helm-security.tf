resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = "1.19.3"
  namespace  = "kube-system"

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

  depends_on = [module.eks]

  values = [
    file("${path.module}/falco-rules.yaml")
  ]

  set {
    name  = "driver.kind"
    value = "modern_ebpf"
  }

  # Pull via ECR pull-through cache (docker-hub) — avoids Docker Hub rate
  # limits and slow pulls over fck-nat from the private subnet.
  set {
    name  = "image.registry"
    value = "286439316079.dkr.ecr.eu-central-1.amazonaws.com"
  }
  set {
    name  = "image.repository"
    value = "docker-hub/falcosecurity/falco-no-driver"
  }
}

resource "helm_release" "tetragon" {
  name       = "tetragon"
  repository = "https://helm.cilium.io/"
  chart      = "tetragon"
  version    = "1.6.1"
  namespace  = "kube-system"

  depends_on = [module.eks]
}
