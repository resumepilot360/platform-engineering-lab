# Human access to EKS through IAM roles + access entries. The Kubernetes
# groups are the same ones the local lab binds in platform/rbac, so the RBAC
# manifests carry over unchanged (docs/iam-model.md).
#
# Roles here are assumed by IAM Identity Center permission sets (SSO) or, for
# break-glass, only with MFA. The break-glass role is the only cluster-admin.
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  p            = data.aws_partition.current.partition
  account_root = "arn:${local.p}:iam::${data.aws_caller_identity.current.account_id}:root"
  personas = {
    admin     = { groups = ["lab:platform-admins"], description = "Platform operators (no secrets, no RBAC writes)" }
    developer = { groups = ["lab:developers"], description = "Developers (dev self-service, staging read)" }
    readonly  = { groups = ["lab:auditors"], description = "Auditors (read-only incl. RBAC, no secrets)" }
  }
}

data "aws_iam_policy_document" "persona_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:SetSourceIdentity", "sts:TagSession"]
    principals {
      type        = "AWS"
      identifiers = var.trusted_principal_arns
    }
  }
}

resource "aws_iam_role" "persona" {
  for_each             = local.personas
  name                 = "${var.cluster_name}-eks-${each.key}"
  path                 = var.iam_path
  permissions_boundary = var.permissions_boundary
  description          = each.value.description
  assume_role_policy   = data.aws_iam_policy_document.persona_assume.json
  max_session_duration = 3600 * 4
  tags                 = var.tags
}

# Persona roles only need to call the EKS API to get a token for kubectl.
data "aws_iam_policy_document" "describe_cluster" {
  statement {
    actions   = ["eks:DescribeCluster", "eks:ListClusters"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "persona" {
  for_each = local.personas
  name     = "eks-describe"
  role     = aws_iam_role.persona[each.key].id
  policy   = data.aws_iam_policy_document.describe_cluster.json
}

resource "aws_eks_access_entry" "persona" {
  for_each          = local.personas
  cluster_name      = var.cluster_name
  principal_arn     = aws_iam_role.persona[each.key].arn
  kubernetes_groups = each.value.groups
  type              = "STANDARD"
  tags              = var.tags
}

# --- Break-glass: MFA required, short sessions, alarmed (see observability) ---
data "aws_iam_policy_document" "breakglass_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:SetSourceIdentity"]
    principals {
      type        = "AWS"
      identifiers = var.breakglass_principal_arns
    }
    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
    condition {
      test     = "NumericLessThan"
      variable = "aws:MultiFactorAuthAge"
      values   = ["900"]
    }
  }
}

resource "aws_iam_role" "breakglass" {
  name                 = "${var.cluster_name}-eks-break-glass"
  path                 = var.iam_path
  permissions_boundary = var.permissions_boundary
  description          = "Emergency cluster-admin. Every assumption triggers an alert."
  assume_role_policy   = data.aws_iam_policy_document.breakglass_assume.json
  max_session_duration = 3600
  tags                 = merge(var.tags, { "lab.platform/break-glass" = "true" })
}

resource "aws_iam_role_policy" "breakglass" {
  name   = "eks-describe"
  role   = aws_iam_role.breakglass.id
  policy = data.aws_iam_policy_document.describe_cluster.json
}

resource "aws_eks_access_entry" "breakglass" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.breakglass.arn
  type          = "STANDARD"
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "breakglass" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.breakglass.arn
  policy_arn    = "arn:${local.p}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.breakglass]
}

# The Terraform apply role needs cluster-admin to install the bootstrap Helm
# releases (Argo CD, LBC). Scoped to that role only; creator admin is disabled.
resource "aws_eks_access_entry" "terraform" {
  count         = var.terraform_role_arn == null ? 0 : 1
  cluster_name  = var.cluster_name
  principal_arn = var.terraform_role_arn
  type          = "STANDARD"
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "terraform" {
  count         = var.terraform_role_arn == null ? 0 : 1
  cluster_name  = var.cluster_name
  principal_arn = var.terraform_role_arn
  policy_arn    = "arn:${local.p}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.terraform]
}
