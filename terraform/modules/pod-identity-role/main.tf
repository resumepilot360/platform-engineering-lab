# IAM role assumable only through EKS Pod Identity, optionally associated with
# one namespace/ServiceAccount. Trust is the fixed service principal, so the
# same role pattern works across clusters (unlike IRSA's per-cluster OIDC trust).
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    dynamic "condition" {
      for_each = var.cluster_arn == null ? [] : [1]
      content {
        test     = "ArnEquals"
        variable = "aws:SourceArn"
        values   = [var.cluster_arn]
      }
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.name
  path                 = var.iam_path
  permissions_boundary = var.permissions_boundary
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each   = toset(var.managed_policies)
  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "inline" {
  count  = var.inline_policy == null ? 0 : 1
  name   = "inline"
  role   = aws_iam_role.this.id
  policy = var.inline_policy
}

resource "aws_eks_pod_identity_association" "this" {
  count           = var.service_account == null ? 0 : 1
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.this.arn
  tags            = var.tags
}
