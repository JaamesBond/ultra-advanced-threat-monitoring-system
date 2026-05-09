# ---------------------------------------------------------------------------
# EFS File System for NOMAD Oasis
#
# One EFS file system shared across bc-prd private subnets.
# EFS CSI driver provisions per-PVC access points under /nomad (basePath),
# so each PersistentVolumeClaim gets its own isolated directory tree while
# sharing the same underlying file system — avoids the 1-PVC-per-FS limit of
# static provisioning.
#
# Lifecycle: files not accessed for 30 days are moved to IA storage
# ($0.025/GB vs $0.30/GB standard) to keep NOMAD archive costs low.
# ---------------------------------------------------------------------------

resource "aws_efs_file_system" "nomad_oasis" {
  creation_token   = "${local.platform_name}-${local.env}-nomad-oasis"
  encrypted        = true
  kms_key_id       = module.eks.kms_key_arn
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = merge(local.common_tags, {
    Name = "${local.platform_name}-${local.env}-nomad-oasis"
  })
}

# ---------------------------------------------------------------------------
# Security group — EFS mount targets
# Allow NFS (TCP 2049) from EKS node SG only. No wider access.
# ---------------------------------------------------------------------------
resource "aws_security_group" "nomad_efs" {
  name        = "${local.platform_name}-${local.env}-nomad-efs-sg"
  description = "EFS mount access for NOMAD Oasis -- EKS nodes only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "NFS from EKS node SG"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    description = "Allow all egress (EFS kernel driver initiates connections)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.platform_name}-${local.env}-nomad-efs-sg"
  })
}

# ---------------------------------------------------------------------------
# Mount targets — one per private subnet (covers both AZs)
# ---------------------------------------------------------------------------
resource "aws_efs_mount_target" "nomad_oasis" {
  for_each = toset(module.vpc.private_subnet_ids)

  file_system_id  = aws_efs_file_system.nomad_oasis.id
  subnet_id       = each.value
  security_groups = [aws_security_group.nomad_efs.id]
}

# ---------------------------------------------------------------------------
# StorageClass — efs-nomad-sc
#
# Security-stack-engineer's NOMAD Helm values must reference this exact name.
# provisioner: efs.csi.aws.com (installed via aws-efs-csi-driver addon)
# provisioningMode: efs-ap — driver creates an EFS access point per PVC,
#   rooted at basePath=/nomad/<pvc-uid>. gidRangeStart/End give each volume
#   a unique GID in the 1000–2000 range, preventing cross-volume access.
# ---------------------------------------------------------------------------
resource "kubernetes_storage_class" "efs_nomad" {
  metadata {
    name = "efs-nomad-sc"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "false"
    }
  }

  storage_provisioner    = "efs.csi.aws.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = false

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.nomad_oasis.id
    directoryPerms   = "0755"
    gidRangeStart    = "1000"
    gidRangeEnd      = "2000"
    basePath         = "/nomad"
  }

  depends_on = [
    module.eks,
    aws_efs_mount_target.nomad_oasis,
  ]
}
