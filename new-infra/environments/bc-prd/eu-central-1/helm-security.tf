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
  # Use "default" not "always": "always" causes endpoint-registration race where pods starting
  # under load (cold-start, scale-up) get identity reserved:unmanaged (id=3) and are implicitly
  # denied before their CNP is installed. Enforcement comes from per-endpoint CNPs in
  # new-infra/k8s/system-netpols/ and per-app cilium-netpol.yaml. Discovered 2026-05-10.
  set {
    name  = "policyEnforcementMode"
    value = "default"
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

  # Allow ESO to spill onto the nomad node when workload nodes are full.
  # t3.medium workload nodes cap at 17 pods; NOMAD Oasis deployment saturated both
  # nodes and left ESO Pending, breaking ClusterSecretStore and all ExternalSecrets.
  # Tolerating dedicated=nomad:NoSchedule does NOT force ESO onto the nomad node —
  # the scheduler still prefers workload slots when available.
  # NOTE: webhook.tolerations and certController.tolerations are included for
  # forward-compatibility; they are no-ops while webhook.create=false.
  set {
    name  = "tolerations[0].key"
    value = "dedicated"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "tolerations[0].value"
    value = "nomad"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }
  set {
    name  = "webhook.tolerations[0].key"
    value = "dedicated"
  }
  set {
    name  = "webhook.tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "webhook.tolerations[0].value"
    value = "nomad"
  }
  set {
    name  = "webhook.tolerations[0].effect"
    value = "NoSchedule"
  }
  set {
    name  = "certController.tolerations[0].key"
    value = "dedicated"
  }
  set {
    name  = "certController.tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "certController.tolerations[0].value"
    value = "nomad"
  }
  set {
    name  = "certController.tolerations[0].effect"
    value = "NoSchedule"
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
          # Existing XDR stack secrets
          "arn:aws:secretsmanager:eu-central-1:${data.aws_caller_identity.current.account_id}:secret:bc/wazuh/*",
          "arn:aws:secretsmanager:eu-central-1:${data.aws_caller_identity.current.account_id}:secret:bc/suricata/*",
          "arn:aws:secretsmanager:eu-central-1:${data.aws_caller_identity.current.account_id}:secret:bc/zeek/*",
          # NOMAD Oasis secrets (shells created in secrets-nomad.tf; values populated by CI)
          aws_secretsmanager_secret.nomad_api.arn,
          aws_secretsmanager_secret.nomad_mongo.arn,
          aws_secretsmanager_secret.nomad_keycloak.arn,
          aws_secretsmanager_secret.nomad_north.arn,
          aws_secretsmanager_secret.nomad_datacite.arn,
        ]
      },
      {
        # ESO needs Decrypt + DescribeKey to read the SM secrets encrypted with the
        # EKS KMS key (module.eks.kms_key_arn == local.nomad_sm_kms_key_id).
        # kms:ViaService restricts this permission to calls originating from
        # Secrets Manager only — ESO cannot use this grant for raw KMS operations.
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = [module.eks.kms_key_arn]
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.eu-central-1.amazonaws.com"
          }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# AWS Load Balancer Controller
#
# Required for ALB ingress when NOMAD Oasis Phase I (ACM + public zone) is
# complete. Deployed now so the CRDs (IngressClassParams, TargetGroupBinding)
# are available in the cluster; no ALB is created until ingress.enabled=true
# in the NOMAD Helm values.
#
# IRSA trust: restricts to the aws-load-balancer-controller ServiceAccount in
# kube-system — least-privilege per-service-account binding.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "alb_controller" {
  name = "${local.platform_name}-${local.env}-alb-controller"

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
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

# ALB Controller IAM policy — inline, sourced from the official AWS policy doc.
# Policy document: https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
# Pinned to the permissions required for v2.x. Update when bumping chart version.
resource "aws_iam_role_policy" "alb_controller" {
  name = "alb-controller-policy"
  role = aws_iam_role.alb_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:GetCoipPoolUsage",
          "ec2:DescribeCoipPools",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTrustStores",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:DescribeUserPoolClient",
          "acm:ListCertificates",
          "acm:DescribeCertificate",
          "iam:ListServerCertificates",
          "iam:GetServerCertificate",
          "waf-regional:GetWebACL",
          "waf-regional:GetWebACLForResource",
          "waf-regional:AssociateWebACL",
          "waf-regional:DisassociateWebACL",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "shield:GetSubscriptionState",
          "shield:DescribeProtection",
          "shield:CreateProtection",
          "shield:DeleteProtection",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateSecurityGroup"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          StringEquals = { "ec2:CreateAction" = "CreateSecurityGroup" }
          Null         = { "aws:RequestedRegion" = "false" }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateTags",
          "ec2:DeleteTags",
        ]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          Null = {
            "aws:RequestedRegion"                     = "false"
            "aws:ResourceTag/ingress.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:DeleteSecurityGroup",
        ]
        Resource = "*"
        Condition = {
          Null = { "aws:ResourceTag/ingress.k8s.aws/cluster" = "false" }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateTargetGroup",
        ]
        Resource = "*"
        Condition = {
          Null = { "aws:RequestedRegion" = "false" }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:DeleteRule",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags",
        ]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*",
        ]
        Condition = {
          Null = {
            "aws:RequestedRegion"                     = "false"
            "aws:ResourceTag/ingress.k8s.aws/cluster" = "true"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags",
        ]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:DeleteTargetGroup",
        ]
        Resource = "*"
        Condition = {
          Null = { "aws:ResourceTag/ingress.k8s.aws/cluster" = "false" }
        }
      },
      {
        Effect = "Allow"
        Action = ["elasticloadbalancing:AddTags"]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*",
        ]
        Condition = {
          StringEquals = { "elasticloadbalancing:CreateAction" = ["CreateTargetGroup", "CreateLoadBalancer"] }
          Null         = { "aws:RequestedRegion" = "false" }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets",
        ]
        Resource = "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:SetWebAcl",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:RemoveListenerCertificates",
          "elasticloadbalancing:ModifyRule",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "helm_release" "aws_load_balancer_controller" {
  name            = "aws-load-balancer-controller"
  repository      = "https://aws.github.io/eks-charts"
  chart           = "aws-load-balancer-controller"
  namespace       = "kube-system"
  version         = "1.13.0"
  cleanup_on_fail = true
  timeout         = 600

  # Must deploy before NOMAD Helm release so ALB IngressClass CRDs exist.
  # Also depends on the Cilium release being up — otherwise the controller
  # pod has no network and will crash-loop during Helm wait.
  depends_on = [
    module.eks,
    helm_release.cilium,
    aws_iam_role.alb_controller,
  ]

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "region"
    value = local.region
  }
  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.alb_controller.arn
  }
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
