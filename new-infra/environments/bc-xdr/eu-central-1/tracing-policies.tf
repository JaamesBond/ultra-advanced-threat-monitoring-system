#--------------------------------------------------------------
# Tetragon TracingPolicies — Tier 1 autonomous kill rules
#
# These are the in-kernel enforcement policies. When a process
# matches, Tetragon issues SIGKILL before the syscall completes.
# No network, no SOAR, no Kafka — pure kernel-level response.
#
# Attack scenarios covered (from xdr-aws-explained.pdf):
#   1. Container compromise → block recon tools (nmap, nc, masscan)
#   2. Lateral movement → block network scanning from pods
#   3. Supply chain / drift → block writes to sensitive paths
#   4. Reverse shells → kill common shell-over-network patterns
#   5. Privilege escalation → block setuid/setgid in containers
#   6. Crypto mining → kill known miner binaries
#--------------------------------------------------------------

# Policy 1: Block reconnaissance tools
# Scenario: attacker gets shell in pod, runs nmap/nc to map network
resource "kubernetes_manifest" "tetragon_block_recon" {
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
# Scenario: attacker establishes callback via bash/python/perl
resource "kubernetes_manifest" "tetragon_block_reverse_shells" {
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
# Scenario: supply chain backdoor writes to /etc/passwd, crontab, systemd
resource "kubernetes_manifest" "tetragon_block_sensitive_writes" {
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
# Scenario: attacker attempts setuid/setgid to escalate
resource "kubernetes_manifest" "tetragon_block_privesc" {
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
# Scenario: compromised container runs mining software
resource "kubernetes_manifest" "tetragon_block_cryptominers" {
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
# Scenario: attacker attempts to break out of container namespace
resource "kubernetes_manifest" "tetragon_block_container_escape" {
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
