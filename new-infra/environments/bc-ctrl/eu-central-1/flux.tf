#--------------------------------------------------------------
# FluxCD — bc-ctrl bootstrap
#
# Installs Flux controllers via Helm, then wires a GitRepository
# pointing at this repo and a Kustomization that reconciles
# new-infra/k8s/wazuh into the bc-ctrl cluster.
#
# This permanently solves the private-endpoint problem:
# Flux runs INSIDE the cluster and pulls from GitHub outbound
# via the NAT gateway — no external cluster access needed.
#
# Gate: deploy_flux (local) — default false.
# Set to true and apply from bastion/SSM (same as other Helm gates):
#
#   # First time only (two-phase bootstrap):
#   terraform apply -target=helm_release.flux[0] \
#                   -target=kubernetes_config_map_v1.flux_cluster_vars[0]
#   terraform apply
#
#   # Subsequently: single terraform apply works because CRDs persist.
#
# After bootstrap, all changes to new-infra/k8s/wazuh/ are
# automatically reconciled within 5 minutes of git push.
#--------------------------------------------------------------

#--------------------------------------------------------------
# Flux controllers — installed via Helm
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

  # Disable notifications controller (not needed for this setup)
  set {
    name  = "notificationController.create"
    value = "false"
  }

  # Image reflector / automation controllers not needed
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

#--------------------------------------------------------------
# ConfigMap: static (non-sensitive) substitution variables
# Flux postBuild.substituteFrom replaces ${VAR} in all manifests
# before applying them. Used to inject AWS_ACCOUNT_ID into
# ECR image references (replaces PLACEHOLDER_AWS_ACCOUNT_ID).
#--------------------------------------------------------------
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

#--------------------------------------------------------------
# GitRepository — Flux watches this branch
#
# Update local.github_repo_url in locals.tf before enabling.
# For a public repo: no secretRef needed.
# For a private repo: create a secret in flux-system namespace:
#   kubectl create secret generic flux-github-credentials \
#     --namespace flux-system \
#     --from-literal=username=git \
#     --from-literal=password=<github-pat>
# Then uncomment the secretRef block below.
#--------------------------------------------------------------
resource "kubernetes_manifest" "flux_gitrepo_ctrl" {
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
      # secretRef = { name = "flux-github-credentials" }  # uncomment for private repo
    }
  }

  depends_on = [helm_release.flux, kubernetes_config_map_v1.flux_cluster_vars]
}

#--------------------------------------------------------------
# Kustomization — reconcile Wazuh stack into bc-ctrl
#
# Flux reconciles new-infra/k8s/wazuh/ every 5 minutes.
# postBuild substitutes ${AWS_ACCOUNT_ID} before applying.
# wait=true: Flux waits for all resources to become Ready
# before reporting reconciliation success.
#--------------------------------------------------------------
resource "kubernetes_manifest" "flux_wazuh" {
  count = local.deploy_flux ? 1 : 0

  manifest = {
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "wazuh"
      namespace = "flux-system"
    }
    spec = {
      interval   = "5m0s"
      path       = "./new-infra/k8s/wazuh"
      prune      = true
      wait       = true
      timeout    = "15m0s"
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

  depends_on = [kubernetes_manifest.flux_gitrepo_ctrl]
}
