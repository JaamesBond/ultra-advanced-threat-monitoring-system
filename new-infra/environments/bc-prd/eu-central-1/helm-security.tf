provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
      command     = "aws"
    }
  }
}

resource "helm_release" "cilium" {
  name            = "cilium"
  repository      = "https://helm.cilium.io/"
  chart           = "cilium"
  version         = "1.19.3"
  namespace       = "kube-system"
  cleanup_on_fail = true

  depends_on = [module.eks]

  set {
    name  = "eni.enabled"
    value = "true"
  }
  set {
    name  = "ipam.mode"
    value = "eni"
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
    value = "true"
  }
  set {
    name  = "policyEnforcementMode"
    value = "always"
  }

  # Phase G: Replace kube-proxy with Cilium eBPF service routing.
  # kube-proxy addon is removed from cluster_addons in eks.tf.
  set {
    name  = "kubeProxyReplacement"
    value = "true"
  }
  set {
    name  = "k8sServiceHost"
    value = trimprefix(module.eks.cluster_endpoint, "https://")
  }
  set {
    name  = "k8sServicePort"
    value = "443"
  }

  # Phase H: WireGuard node-to-node encryption.
  # UDP 51871 is already permitted by the node SG ingress_self_all rule.
  set {
    name  = "encryption.enabled"
    value = "true"
  }
  set {
    name  = "encryption.type"
    value = "wireguard"
  }
  set {
    name  = "encryption.nodeEncryption"
    value = "true"
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
  wait             = false

  depends_on = [module.eks]

  values = [
    file("${path.module}/falco-rules.yaml")
  ]

  set {
    name  = "driver.kind"
    value = "modern_ebpf"
  }
  set {
    name  = "falcoctl.artifact.install.enabled"
    value = "false"
  }
  set {
    name  = "falcoctl.artifact.follow.enabled"
    value = "false"
  }
  set {
    name  = "collectors.containerEngine.enabled"
    value = "true"
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

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  version          = "0.10.7"
  cleanup_on_fail  = true
  wait             = false
  timeout          = 600

  depends_on = [module.eks]

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.external_secrets.arn
  }

  # Disable the validating webhook entirely — the reconcile loop does not need it.
  # The webhook only validates user-submitted manifests; disabling it eliminates the
  # cert-controller startup race that caused ClusterSecretStore creation to fail.
  set {
    name  = "webhook.create"
    value = "false"
  }
}

resource "aws_iam_role" "external_secrets" {
  name = "bc-uatms-prd-external-secrets"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:external-secrets:external-secrets"
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "external_secrets_secrets_manager" {
  name = "external-secrets-secrets-manager"
  role = aws_iam_role.external_secrets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          "arn:aws:secretsmanager:eu-central-1:${data.aws_caller_identity.current.account_id}:secret:bc/wazuh/*",
          "arn:aws:secretsmanager:eu-central-1:${data.aws_caller_identity.current.account_id}:secret:bc/suricata/*",
          "arn:aws:secretsmanager:eu-central-1:${data.aws_caller_identity.current.account_id}:secret:bc/zeek/*",
        ]
      }
    ]
  })
}

# resource "helm_release" "shuffle" {
#   name             = "shuffle"
#   chart            = "${path.module}/../../../k8s/shuffle"
#   namespace        = "shuffle"
#   create_namespace = true
#   cleanup_on_fail  = true
#   timeout          = 900
#   wait             = true
#
#   depends_on = [module.eks]
#
#   set {
#     name  = "opensearch.sysctlInit.enabled"
#     value = "true"
#   }
# }
