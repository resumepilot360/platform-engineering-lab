# EKS cluster with:
# - API-only authentication (access entries; no aws-auth ConfigMap) and no
#   implicit admin for the creator (bootstrap_cluster_creator_admin_permissions = false)
# - Secret envelope encryption with a customer-managed KMS key
# - all control-plane log types to a pre-created, KMS-encrypted log group
# - private endpoint + public endpoint restricted to an allow-list
# - Terraform-owned add-ons (bootstrap_self_managed_addons = false)
# - Graviton managed node group, IMDSv2 required, encrypted gp3 root volumes
data "aws_partition" "current" {}

locals {
  p = data.aws_partition.current.partition
}

# --- IAM: cluster role ---------------------------------------------------------
data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name                 = "${var.name}-cluster"
  path                 = var.iam_path
  permissions_boundary = var.permissions_boundary
  assume_role_policy   = data.aws_iam_policy_document.cluster_assume.json
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.p}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Envelope encryption of Kubernetes Secrets with our CMK.
data "aws_iam_policy_document" "cluster_kms" {
  statement {
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ListGrants", "kms:DescribeKey"]
    resources = [var.secrets_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "cluster_kms" {
  name   = "secrets-envelope-encryption"
  role   = aws_iam_role.cluster.id
  policy = data.aws_iam_policy_document.cluster_kms.json
}

# --- Logs ----------------------------------------------------------------------
# Pre-created so retention and KMS are ours (EKS would create it unencrypted).
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
  tags              = var.tags
}

# --- Cluster -------------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name                          = var.name
  version                       = var.kubernetes_version
  role_arn                      = aws_iam_role.cluster.arn
  bootstrap_self_managed_addons = false
  enabled_cluster_log_types     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = var.secrets_kms_key_arn
    }
  }

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = length(var.public_access_cidrs) > 0
    public_access_cidrs     = length(var.public_access_cidrs) > 0 ? var.public_access_cidrs : null
  }

  upgrade_policy {
    support_type = "STANDARD" # avoid silent extended-support charges
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy_attachment.cluster, aws_cloudwatch_log_group.cluster]
}

# --- IAM: node role --------------------------------------------------------------
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name                 = "${var.name}-node"
  path                 = var.iam_path
  permissions_boundary = var.permissions_boundary
  assume_role_policy   = data.aws_iam_policy_document.node_assume.json
  tags                 = var.tags
}

# Node role is deliberately minimal: workloads get AWS access via Pod Identity,
# never via the node role. (CNI permissions live here only because the VPC CNI
# runs on the host network; scope it to IRSA/Pod Identity later if desired.)
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryPullOnly",
  ])
  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.p}:iam::aws:policy/${each.value}"
}

resource "aws_launch_template" "node" {
  name_prefix            = "${var.name}-node-"
  update_default_version = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # pods cannot reach node credentials
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_disk_gib
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.ebs_kms_key_arn
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.name}-node" })
  }

  tags = var.tags
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  ami_type        = "AL2023_ARM_64_STANDARD"
  capacity_type   = var.capacity_type
  instance_types  = var.instance_types

  scaling_config {
    min_size     = var.node_min
    desired_size = var.node_desired
    max_size     = var.node_max
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  labels = { "lab.platform/role" = "worker" }
  tags   = var.tags

  depends_on = [aws_iam_role_policy_attachment.node, aws_eks_addon.vpc_cni]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size] # owned by the autoscaler once added
  }
}

# --- Add-ons (Terraform-owned) ---------------------------------------------------
data "aws_eks_addon_version" "this" {
  for_each           = toset(["vpc-cni", "kube-proxy", "coredns", "eks-pod-identity-agent", "aws-ebs-csi-driver"])
  addon_name         = each.value
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  addon_version               = data.aws_eks_addon_version.this["vpc-cni"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  # NetworkPolicy enforcement (eBPF) so Phase 6 policies carry over.
  configuration_values = jsonencode({ enableNetworkPolicy = "true" })
  tags                 = var.tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  addon_version               = data.aws_eks_addon_version.this["kube-proxy"].version
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = data.aws_eks_addon_version.this["eks-pod-identity-agent"].version
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags
}

# CoreDNS and EBS CSI need schedulable nodes.
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  addon_version               = data.aws_eks_addon_version.this["coredns"].version
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags
  depends_on                  = [aws_eks_node_group.default]
}

module "ebs_csi_role" {
  source               = "../pod-identity-role"
  name                 = "${var.name}-ebs-csi"
  iam_path             = var.iam_path
  permissions_boundary = var.permissions_boundary
  managed_policies     = ["arn:${local.p}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
  inline_policy        = data.aws_iam_policy_document.ebs_kms.json
  tags                 = var.tags
}

# EBS CSI must be able to create volumes encrypted with our EBS key.
data "aws_iam_policy_document" "ebs_kms" {
  statement {
    actions   = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]
    resources = [var.ebs_kms_key_arn]
    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
  statement {
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = [var.ebs_kms_key_arn]
  }
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = data.aws_eks_addon_version.this["aws-ebs-csi-driver"].version
  resolve_conflicts_on_update = "OVERWRITE"
  pod_identity_association {
    role_arn        = module.ebs_csi_role.arn
    service_account = "ebs-csi-controller-sa"
  }
  tags       = var.tags
  depends_on = [aws_eks_node_group.default, aws_eks_addon.pod_identity]
}
