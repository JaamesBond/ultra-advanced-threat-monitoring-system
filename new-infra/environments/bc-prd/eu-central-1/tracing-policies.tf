#--------------------------------------------------------------
# Tetragon TracingPolicies — Tier 1 autonomous kill rules (bc-prd)
#
# In-kernel enforcement. When a process matches, Tetragon issues
# SIGKILL before the syscall completes. No network, no SOAR,
# no Kafka — pure kernel-level response.
#
# Policies:
#   1. Block reconnaissance tools (nmap, nc, masscan, etc.)
#   2. Block reverse shell patterns (mkfifo, bash -i)
#   3. Block sensitive file writes (/etc/passwd, shadow, sudoers)
#   4. Block privilege escalation (nsenter, unshare, setuid)
#   5. Block crypto miners (xmrig, ethminer, etc.)
#   6. Block container escape tools (cdk, deepce, BOtB)
#
# Gated by local.deploy_security_helm (same as helm-security.tf).
#--------------------------------------------------------------

# Policy 1: Block reconnaissance tools
resource "kubernetes_manifest" "tetragon_block_recon" {
  count = local.deploy_security_helm ? 1 : 0

  manifest = {
    apiVersion = "cilium.io/v1alpha1"
    kind       = "TracingPolicy"
    metadata = {
      name = "block-recon-tools"
    }
    spec = {
      kprobes = [{
        call = "sys_execve"
        args = [{
          index = 0
          type  = "string"
        }]
        selectors = [{
          matchArgs = [{
            index    = 0
            operator = "In"
            values = [
              "nmap", "masscan", "zmap",
              "nc", "ncat", "netcat",
              "socat", "chisel",
              "rustscan", "naabu",
            ]
          }]
          matchActions = [{
            action = "Sigkill"
          }]
        }]
      }]
    }
  }

  depends_on = [helm_release.tetragon]
}

# Policy 2: Block reverse shell patterns
resource "kubernetes_manifest" "tetragon_block_reverse_shells" {
  count = local.deploy_security_helm ? 1 : 0

  manifest = {
    apiVersion = "cilium.io/v1alpha1"
    kind       = "TracingPolicy"
    metadata = {
      name = "block-reverse-shells"
    }
    spec = {
      kprobes = [{
        call = "sys_execve"
        args = [{
          index = 0
          type  = "string"
        }]
        selectors = [{
          matchArgs = [{
            index    = 0
            operator = "In"
            values = [
              "bash -i",
              "mkfifo", "mknod",
            ]
          }]
          matchNamespaces = [{
            namespace = "any"
            operator  = "NotIn"
            values    = ["host_mnt"]
          }]
          matchActions = [{
            action = "Sigkill"
          }]
        }]
      }]
    }
  }

  depends_on = [helm_release.tetragon]
}

# Policy 3: Block sensitive file writes in containers
resource "kubernetes_manifest" "tetragon_block_sensitive_writes" {
  count = local.deploy_security_helm ? 1 : 0

  manifest = {
    apiVersion = "cilium.io/v1alpha1"
    kind       = "TracingPolicy"
    metadata = {
      name = "block-sensitive-file-writes"
    }
    spec = {
      kprobes = [{
        call = "security_file_permission"
        args = [
          {
            index = 0
            type  = "file"
          },
          {
            index = 1
            type  = "int"
          },
        ]
        selectors = [{
          matchArgs = [
            {
              index    = 0
              operator = "Prefix"
              values = [
                "/etc/passwd",
                "/etc/shadow",
                "/etc/sudoers",
                "/etc/crontab",
                "/etc/cron.d",
                "/root/.ssh/authorized_keys",
              ]
            },
            {
              index    = 1
              operator = "Equal"
              values   = ["2"] # MAY_WRITE
            },
          ]
          matchNamespaces = [{
            namespace = "any"
            operator  = "NotIn"
            values    = ["host_mnt"]
          }]
          matchActions = [{
            action = "Sigkill"
          }]
        }]
      }]
    }
  }

  depends_on = [helm_release.tetragon]
}

# Policy 4: Block privilege escalation in containers
resource "kubernetes_manifest" "tetragon_block_privesc" {
  count = local.deploy_security_helm ? 1 : 0

  manifest = {
    apiVersion = "cilium.io/v1alpha1"
    kind       = "TracingPolicy"
    metadata = {
      name = "block-privilege-escalation"
    }
    spec = {
      kprobes = [{
        call = "sys_execve"
        args = [{
          index = 0
          type  = "string"
        }]
        selectors = [{
          matchArgs = [{
            index    = 0
            operator = "In"
            values = [
              "chmod u+s", "chmod g+s",
              "chown root",
              "nsenter",
              "unshare",
            ]
          }]
          matchNamespaces = [{
            namespace = "any"
            operator  = "NotIn"
            values    = ["host_mnt"]
          }]
          matchActions = [{
            action = "Sigkill"
          }]
        }]
      }]
    }
  }

  depends_on = [helm_release.tetragon]
}

# Policy 5: Block crypto miners
resource "kubernetes_manifest" "tetragon_block_cryptominers" {
  count = local.deploy_security_helm ? 1 : 0

  manifest = {
    apiVersion = "cilium.io/v1alpha1"
    kind       = "TracingPolicy"
    metadata = {
      name = "block-cryptominers"
    }
    spec = {
      kprobes = [{
        call = "sys_execve"
        args = [{
          index = 0
          type  = "string"
        }]
        selectors = [{
          matchArgs = [{
            index    = 0
            operator = "In"
            values = [
              "xmrig", "xmr-stak", "minerd",
              "cpuminer", "cgminer", "bfgminer",
              "ethminer", "nbminer", "t-rex",
              "phoenixminer", "lolminer",
            ]
          }]
          matchActions = [{
            action = "Sigkill"
          }]
        }]
      }]
    }
  }

  depends_on = [helm_release.tetragon]
}

# Policy 6: Block container escape tools
resource "kubernetes_manifest" "tetragon_block_container_escape" {
  count = local.deploy_security_helm ? 1 : 0

  manifest = {
    apiVersion = "cilium.io/v1alpha1"
    kind       = "TracingPolicy"
    metadata = {
      name = "block-container-escape"
    }
    spec = {
      kprobes = [{
        call = "sys_execve"
        args = [{
          index = 0
          type  = "string"
        }]
        selectors = [{
          matchArgs = [{
            index    = 0
            operator = "In"
            values = [
              "cdk",
              "deepce",
              "BOtB",
              "amicontained",
              "kubectl",
            ]
          }]
          matchNamespaces = [{
            namespace = "any"
            operator  = "NotIn"
            values    = ["host_mnt"]
          }]
          matchActions = [{
            action = "Sigkill"
          }]
        }]
      }]
    }
  }

  depends_on = [helm_release.tetragon]
}
