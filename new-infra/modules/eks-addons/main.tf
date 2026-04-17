#--------------------------------------------------------------
# EKS Addons module
#
# Installs three foundational Helm charts on an EKS cluster:
#   1. AWS Load Balancer Controller  — needed for internal NLBs
#   2. external-secrets operator     — AWS Secrets Manager → K8s Secrets
#   3. cert-manager                  — TLS automation (Wazuh Indexer certs)
#   4. external-dns                  — Route53 record management
#
# IAM: uses IRSA (AssumeRoleWithWebIdentity via OIDC) for all addons.
# Pod Identity (eks-auth:AssumeRoleForPodIdentity) is blocked by an
# org-level SCP in this account and cannot be used.
#--------------------------------------------------------------

terraform {
  required_version = ">= 1.5.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.32"
    }
  }
}

locals {
  common_tags = merge(var.tags, {
    Module = "eks-addons"
  })
  # Extract OIDC provider URL (without https://) from the ARN
  # ARN format: arn:aws:iam::<account>:oidc-provider/<url>
  oidc_provider = replace(var.oidc_provider_arn, "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/", "")
}

data "aws_caller_identity" "current" {}

#--------------------------------------------------------------
# 1. AWS Load Balancer Controller
#--------------------------------------------------------------
resource "aws_iam_role" "aws_lb_controller" {
  count = var.install_load_balancer_controller ? 1 : 0

  name = "${var.cluster_name}-aws-lb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_policy" "aws_lb_controller" {
  count = var.install_load_balancer_controller ? 1 : 0

  name        = "${var.cluster_name}-aws-lb-controller"
  description = "Permissions for AWS Load Balancer Controller"
  policy      = file("${path.module}/policies/aws-lb-controller.json")

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "aws_lb_controller" {
  count = var.install_load_balancer_controller ? 1 : 0

  role       = aws_iam_role.aws_lb_controller[0].name
  policy_arn = aws_iam_policy.aws_lb_controller[0].arn
}

resource "helm_release" "aws_lb_controller" {
  count = var.deploy_helm_releases && var.install_load_balancer_controller ? 1 : 0

  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  version          = var.aws_lb_controller_chart_version
  namespace        = "kube-system"
  create_namespace = false
  atomic           = true
  replace          = true
  cleanup_on_fail  = true
  timeout          = 600

  values = [
    yamlencode({
      clusterName = var.cluster_name
      region      = var.region
      vpcId       = var.vpc_id
      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.aws_lb_controller[0].arn
        }
      }
      nodeSelector = var.platform_node_label
      tolerations = [{
        key      = "dedicated"
        operator = "Equal"
        value    = "platform"
        effect   = "NoSchedule"
      }]
      replicaCount = 2
      podDisruptionBudget = {
        maxUnavailable = 1
      }
      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
      enableServiceMutatorWebhook = false
    })
  ]
}

#--------------------------------------------------------------
# 2. external-secrets operator
#--------------------------------------------------------------
resource "aws_iam_role" "external_secrets" {
  count = var.install_external_secrets ? 1 : 0

  name = "${var.cluster_name}-external-secrets"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider}:sub" = "system:serviceaccount:external-secrets:external-secrets"
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_policy" "external_secrets" {
  count = var.install_external_secrets ? 1 : 0

  name        = "${var.cluster_name}-external-secrets"
  description = "Read access to bc/* secrets for external-secrets operator"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecrets"
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:bc/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.region}.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "external_secrets" {
  count = var.install_external_secrets ? 1 : 0

  role       = aws_iam_role.external_secrets[0].name
  policy_arn = aws_iam_policy.external_secrets[0].arn
}

resource "helm_release" "external_secrets" {
  count = var.deploy_helm_releases && var.install_external_secrets ? 1 : 0

  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.external_secrets_chart_version
  namespace        = "external-secrets"
  create_namespace = true
  atomic           = true
  replace          = true
  cleanup_on_fail  = true
  timeout          = 600

  values = [
    yamlencode({
      installCRDs  = true
      replicaCount = 2
      serviceAccount = {
        create = true
        name   = "external-secrets"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.external_secrets[0].arn
        }
      }
      nodeSelector = var.platform_node_label
      tolerations = [{
        key      = "dedicated"
        operator = "Equal"
        value    = "platform"
        effect   = "NoSchedule"
      }]
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { cpu = "300m", memory = "512Mi" }
      }
      webhook = {
        replicaCount = 2
        nodeSelector = var.platform_node_label
      }
      certController = {
        replicaCount = 1
        nodeSelector = var.platform_node_label
      }
    })
  ]
}

#--------------------------------------------------------------
# 3. cert-manager
#--------------------------------------------------------------
resource "helm_release" "cert_manager" {
  count = var.deploy_helm_releases && var.install_cert_manager ? 1 : 0

  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version
  namespace        = "cert-manager"
  create_namespace = true
  atomic           = true
  replace          = true
  cleanup_on_fail  = true
  timeout          = 600

  values = [
    yamlencode({
      crds = {
        enabled = true
        keep    = true
      }
      replicaCount = 2
      nodeSelector = var.platform_node_label
      tolerations = [{
        key      = "dedicated"
        operator = "Equal"
        value    = "platform"
        effect   = "NoSchedule"
      }]
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { cpu = "300m", memory = "512Mi" }
      }
      webhook = {
        replicaCount = 2
        nodeSelector = var.platform_node_label
      }
      cainjector = {
        replicaCount = 2
        nodeSelector = var.platform_node_label
      }
      prometheus = {
        enabled = false
      }
    })
  ]
}

#--------------------------------------------------------------
# 4. external-dns
#--------------------------------------------------------------
resource "aws_iam_role" "external_dns" {
  count = var.install_external_dns ? 1 : 0

  name = "${var.cluster_name}-external-dns"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider}:sub" = "system:serviceaccount:external-dns:external-dns"
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_policy" "external_dns" {
  count = var.install_external_dns ? 1 : 0

  name        = "${var.cluster_name}-external-dns"
  description = "Allows external-dns to manage Route53 records in scoped hosted zones"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ChangeRecords"
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
        ]
        Resource = length(var.external_dns_route53_zone_arns) > 0 ? var.external_dns_route53_zone_arns : ["arn:aws:route53:::hostedzone/*"]
      },
      {
        Sid      = "ListZones"
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones"]
        Resource = ["*"]
      },
      {
        Sid      = "GetChange"
        Effect   = "Allow"
        Action   = ["route53:GetChange"]
        Resource = ["arn:aws:route53:::change/*"]
      },
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "external_dns" {
  count = var.install_external_dns ? 1 : 0

  role       = aws_iam_role.external_dns[0].name
  policy_arn = aws_iam_policy.external_dns[0].arn
}

resource "helm_release" "external_dns" {
  count = var.deploy_helm_releases && var.install_external_dns ? 1 : 0

  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  version          = var.external_dns_chart_version
  namespace        = "external-dns"
  create_namespace = true
  atomic           = true
  cleanup_on_fail  = true
  timeout          = 300

  values = [
    yamlencode({
      provider = { name = "aws" }
      env = [
        { name = "AWS_DEFAULT_REGION", value = var.region }
      ]
      extraArgs = concat(
        ["--aws-zone-type=private"],
        var.external_dns_domain_filter != "" ? ["--domain-filter=${var.external_dns_domain_filter}"] : [],
      )
      policy     = "upsert-only"
      registry   = "txt"
      txtOwnerId = var.cluster_name
      txtPrefix  = "edns-"
      sources    = ["service"]
      serviceAccount = {
        create = true
        name   = "external-dns"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.external_dns[0].arn
        }
      }
      nodeSelector = var.platform_node_label
      tolerations = [{
        key      = "dedicated"
        operator = "Equal"
        value    = "platform"
        effect   = "NoSchedule"
      }]
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "200m", memory = "256Mi" }
      }
      logLevel  = "info"
      logFormat = "json"
    })
  ]
}
