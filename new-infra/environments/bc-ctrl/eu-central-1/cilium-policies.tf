#--------------------------------------------------------------
# Cilium Clusterwide Network Policies — bc-ctrl
#
# Default-deny-with-exceptions model:
#   Once any CiliumClusterwideNetworkPolicy (CCNP) selects a pod,
#   Cilium enforces it. Pods not matched by any CCNP are in
#   "policy-disabled" state and pass all traffic — so these three
#   policies together create an implicit default-deny for namespaces
#   where workloads exist, while staying safe for system components.
#
# Policy 1 — allow-kube-system
#   kube-system pods are fully unrestricted (ingress + egress).
#   This covers: kube-proxy, coredns, aws-node (vpc-cni),
#   eks-pod-identity-agent, Tetragon, Falco, Cilium DaemonSet,
#   CloudWatch agent, hubble-relay. Too many system components with
#   varying connectivity needs — blanket allow is the standard
#   EKS practice.
#
# Policy 2 — allow-dns-egress
#   Every pod (wildcard selector) may egress to CoreDNS pods on
#   UDP/TCP 53. Matches by pod identity label (k8s-app=kube-dns)
#   rather than ClusterIP — survives CoreDNS restarts.
#
# Policy 3 — allow-same-namespace
#   Pods may communicate with other pods in the same namespace.
#   Uses Cilium's per-pod self-referential label expression
#   $(k8s:io.kubernetes.pod.namespace) — no per-namespace policy
#   duplication needed.
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
