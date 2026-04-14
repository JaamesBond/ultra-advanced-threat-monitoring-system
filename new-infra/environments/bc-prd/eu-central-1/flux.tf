#--------------------------------------------------------------
# FluxCD — bc-prd bootstrap
#
# Same pattern as bc-ctrl/flux.tf.
# Reconciles:
#   - new-infra/k8s/wazuh/agent   → Wazuh Agent DaemonSet
#   - new-infra/k8s/suricata      → Suricata NIDS DaemonSet
#
# Gate: deploy_flux (local) — default false.
# Set to true and apply from bastion/SSM after EKS cluster is up.
#--------------------------------------------------------------

resource "helm_release" "flux" {
  count = local.deploy_flux ? 1 : 0

  name             = "flux2"
  namespace        = "flux-system"
  repository       = "https://fluxcd-community.github.io/helm-charts"
  chart            = "flux2"
  version          = "2.14.1"
  create_namespace = true
  atomic           = true
  cleanup_on_fail  = true
  timeout          = 600

  set {
    name  = "notificationController.create"
    value = "false"
  }

  set {
    name  = "imageReflectionController.create"
    value = "false"
  }

  set {
    name  = "imageAutomationController.create"
    value = "false"
  }

  depends_on = [module.eks, module.eks_addons]
}

resource "kubernetes_config_map_v1" "flux_cluster_vars" {
  count = local.deploy_flux ? 1 : 0

  metadata {
    name      = "cluster-vars"
    namespace = "flux-system"
  }

  data = {
    AWS_ACCOUNT_ID = data.aws_caller_identity.current.account_id
    REGION         = local.region
    CLUSTER_NAME   = local.eks_cluster_name
  }

  depends_on = [helm_release.flux]
}

resource "kubernetes_manifest" "flux_gitrepo_prd" {
  count = local.deploy_flux ? 1 : 0

  manifest = {
    apiVersion = "source.toolkit.fluxcd.io/v1"
    kind       = "GitRepository"
    metadata = {
      name      = "xdr-platform"
      namespace = "flux-system"
    }
    spec = {
      interval = "1m0s"
      ref = {
        branch = "main"
      }
      url = local.github_repo_url
    }
  }

  depends_on = [helm_release.flux, kubernetes_config_map_v1.flux_cluster_vars]
}

#--------------------------------------------------------------
# Kustomization: Wazuh Agent DaemonSet (bc-prd)
#--------------------------------------------------------------
resource "kubernetes_manifest" "flux_wazuh_agent" {
  count = local.deploy_flux ? 1 : 0

  manifest = {
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "wazuh-agent"
      namespace = "flux-system"
    }
    spec = {
      interval   = "5m0s"
      path       = "./new-infra/k8s/wazuh/agent"
      prune      = true
      wait       = true
      timeout    = "10m0s"
      sourceRef = {
        kind = "GitRepository"
        name = "xdr-platform"
      }
      postBuild = {
        substituteFrom = [
          {
            kind     = "ConfigMap"
            name     = "cluster-vars"
            optional = false
          }
        ]
      }
    }
  }

  depends_on = [kubernetes_manifest.flux_gitrepo_prd]
}

#--------------------------------------------------------------
# Kustomization: Suricata NIDS DaemonSet (bc-prd)
# Receives traffic-mirrored packets from bc-prd ENIs via NLB.
#--------------------------------------------------------------
resource "kubernetes_manifest" "flux_suricata" {
  count = local.deploy_flux ? 1 : 0

  manifest = {
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "suricata"
      namespace = "flux-system"
    }
    spec = {
      interval   = "5m0s"
      path       = "./new-infra/k8s/suricata"
      prune      = true
      wait       = true
      timeout    = "10m0s"
      sourceRef = {
        kind = "GitRepository"
        name = "xdr-platform"
      }
      postBuild = {
        substituteFrom = [
          {
            kind     = "ConfigMap"
            name     = "cluster-vars"
            optional = false
          }
        ]
      }
    }
  }

  depends_on = [kubernetes_manifest.flux_gitrepo_prd]
}
