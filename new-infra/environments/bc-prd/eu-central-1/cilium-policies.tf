#--------------------------------------------------------------
# Cilium Clusterwide Network Policies — bc-prd
#
# Default-deny-with-exceptions model (same logic as bc-ctrl):
#   Policy 1 — allow-kube-system: unrestricted for system pods
#   Policy 2 — allow-dns-egress: all pods → CoreDNS UDP/TCP 53
#   Policy 3 — allow-same-namespace: intra-namespace pod comms
#   Policy 4 — allow-wazuh-agent-egress (bc-prd only):
#               Wazuh Agent DaemonSet → Wazuh Manager in bc-xdr
#               Traffic path: pod → TGW spoke-rt → bc-xdr
#               10.11.0.0/16 TCP 1514 (events) + 1515 (enrollment)
#
# Gated by local.deploy_cilium_helm (same as cilium.tf).
# ⚠ Apply ONLY after rolling-restart of all non-kube-system pods
#   has completed and cilium endpoint list shows non-zero identities.
#--------------------------------------------------------------

# Policy 1: kube-system — fully unrestricted
resource "kubernetes_manifest" "cilium_allow_kube_system" {
  count = local.deploy_cilium_helm ? 1 : 0

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumClusterwideNetworkPolicy"
    metadata = {
      name = "allow-kube-system"
    }
    spec = {
      description = "kube-system: unrestricted ingress + egress for all EKS system components"
      endpointSelector = {
        matchLabels = {
          "k8s:io.kubernetes.pod.namespace" = "kube-system"
        }
      }
      ingress = [{
        fromEntities = ["all"]
      }]
      egress = [{
        toEntities = ["all"]
      }]
    }
  }

  depends_on = [helm_release.cilium]
}

# Policy 2: DNS egress — all pods → CoreDNS UDP/TCP 53
resource "kubernetes_manifest" "cilium_allow_dns_egress" {
  count = local.deploy_cilium_helm ? 1 : 0

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumClusterwideNetworkPolicy"
    metadata = {
      name = "allow-dns-egress"
    }
    spec = {
      description = "All pods: egress to CoreDNS on UDP/TCP 53"
      endpointSelector = {}
      egress = [{
        toEndpoints = [{
          matchLabels = {
            "k8s:k8s-app" = "kube-dns"
          }
        }]
        toPorts = [{
          ports = [
            { port = "53", protocol = "UDP" },
            { port = "53", protocol = "TCP" },
          ]
        }]
      }]
    }
  }

  depends_on = [helm_release.cilium]
}

# Policy 3: same-namespace — pods may talk to pods in same namespace
resource "kubernetes_manifest" "cilium_allow_same_namespace" {
  count = local.deploy_cilium_helm ? 1 : 0

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumClusterwideNetworkPolicy"
    metadata = {
      name = "allow-same-namespace"
    }
    spec = {
      description = "All pods: ingress + egress within the same namespace"
      endpointSelector = {}
      ingress = [{
        fromEndpoints = [{
          matchExpressions = [{
            key      = "k8s:io.kubernetes.pod.namespace"
            operator = "In"
            values   = ["$(k8s:io.kubernetes.pod.namespace)"]
          }]
        }]
      }]
      egress = [{
        toEndpoints = [{
          matchExpressions = [{
            key      = "k8s:io.kubernetes.pod.namespace"
            operator = "In"
            values   = ["$(k8s:io.kubernetes.pod.namespace)"]
          }]
        }]
      }]
    }
  }

  depends_on = [helm_release.cilium]
}

# Policy 4 (bc-prd only): Wazuh Agent → Wazuh Manager in bc-xdr
#
# The Wazuh Agent DaemonSet (namespace: wazuh, app: wazuh-agent) ships
# security events to the Wazuh Manager in bc-xdr (10.11.0.0/16) via TGW.
# Port 1514 = event/alert data, port 1515 = agent enrollment/registration.
resource "kubernetes_manifest" "cilium_allow_wazuh_agent_egress" {
  count = local.deploy_cilium_helm ? 1 : 0

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumClusterwideNetworkPolicy"
    metadata = {
      name = "allow-wazuh-agent-egress"
    }
    spec = {
      description = "Wazuh Agent: egress to Wazuh Manager (bc-xdr 10.11.0.0/16) on TCP 1514 + 1515 via TGW"
      endpointSelector = {
        matchLabels = {
          "k8s:app"                         = "wazuh-agent"
          "k8s:io.kubernetes.pod.namespace" = "wazuh"
        }
      }
      egress = [{
        toCIDR = ["10.11.0.0/16"]
        toPorts = [{
          ports = [
            { port = "1514", protocol = "TCP" },
            { port = "1515", protocol = "TCP" },
          ]
        }]
      }]
    }
  }

  depends_on = [helm_release.cilium]
}
