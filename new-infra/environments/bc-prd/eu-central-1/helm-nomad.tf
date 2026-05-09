# ---------------------------------------------------------------------------
# NOMAD Oasis — Helm Release
#
# Chart: fairmat-nfdi.github.io/nomad-helm-charts, chart name "default"
# Pinned version: 1.4.2 (appVersion 1.4.2, released 2026-04-27)
# Values: nomad-values.yaml (same directory)
#
# Cold-start ordering is explicit via depends_on:
#   1. EBS CSI addon (gp3 PVCs for MongoDB/ES/PostgreSQL)
#   2. EFS CSI addon (efs-nomad-sc PVCs for NOMAD shared volumes)
#   3. StorageClass efs-nomad-sc (kubernetes_storage_class.efs_nomad in efs-nomad.tf)
#   4. AWS LBC Helm release (IngressClass/IngressClassParams CRDs must exist)
#   5. External Secrets Helm release (ESO must be running before ExternalSecrets are applied)
#
# wait=false because EFS PVC binding is deferred until pods land on nodes with
# the efs-csi-node DaemonSet running. The CI pipeline polls with:
#   kubectl -n nomad-oasis wait --for=condition=Ready pod -l app.kubernetes.io/instance=nomad-oasis --timeout=600s
#
# timeout=900 covers slow Elasticsearch + Temporal init on cold EFS.
# ---------------------------------------------------------------------------

resource "helm_release" "nomad_oasis" {
  name             = "nomad-oasis"
  repository       = "https://fairmat-nfdi.github.io/nomad-helm-charts"
  chart            = "default"
  version          = "1.4.2" # latest stable — appVersion 1.4.2, released 2026-04-27
  namespace        = "nomad-oasis"
  create_namespace = true
  cleanup_on_fail  = true
  timeout          = 900
  wait             = false # PVC binding on EFS can be slow; CI polls separately

  values = [file("${path.module}/nomad-values.yaml")]

  # Explicit cold-start ordering — do not reorder.
  # EBS CSI and EFS CSI are cluster_addons in eks.tf (module.eks handles them);
  # kubernetes_storage_class.efs_nomad is in efs-nomad.tf.
  depends_on = [
    module.eks,
    helm_release.aws_load_balancer_controller,
    helm_release.external_secrets,
    kubernetes_storage_class.efs_nomad,
  ]
}
