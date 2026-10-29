# Account bootstrap (applied once by a human admin, see terraform/bootstrap).
# GitHub Actions → AWS without long-lived keys: an IAM OIDC provider for
# token.actions.githubusercontent.com and three roles whose trust policies pin
# the repository and the ref/environment (docs/iam-model.md, aws-architecture §3).
#
#   ci-ecr-push : main branch only; push to this environment's ECR repos only
#   tf-plan     : pull requests + main; read-only + state read
#   tf-apply    : GitHub environment "production" only (required reviewers);
#                 service-scoped permissions; may create IAM roles only under
#                 var.iam_path AND only with the permissions boundary attached
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  p               = data.aws_partition.current.partition
  account         = data.aws_caller_identity.current.account_id
  repo_sub        = "repo:${var.github_repository}"
  oidc_arn        = var.create_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:${local.p}:iam::${local.account}:oidc-provider/token.actions.githubusercontent.com"
  role_arn_prefix = "arn:${local.p}:iam::${local.account}:role${var.iam_path}"
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}

data "aws_iam_policy_document" "trust" {
  for_each = {
    ci-ecr-push = ["${local.repo_sub}:ref:refs/heads/main"]
    tf-plan     = ["${local.repo_sub}:pull_request", "${local.repo_sub}:ref:refs/heads/main"]
    tf-apply    = ["${local.repo_sub}:environment:${var.apply_environment}"]
  }
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value
    }
  }
}

# --- ci-ecr-push -----------------------------------------------------------------
resource "aws_iam_role" "ci_ecr_push" {
  name                 = "${var.name}-ci-ecr-push"
  path                 = var.iam_path
  assume_role_policy   = data.aws_iam_policy_document.trust["ci-ecr-push"].json
  max_session_duration = 3600
  tags                 = var.tags
}

data "aws_iam_policy_document" "ci_ecr_push" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload",
      "ecr:DescribeImages", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
    ]
    resources = ["arn:${local.p}:ecr:${var.region}:${local.account}:repository/${var.ecr_repository_prefix}/*"]
  }
  statement {
    sid       = "UseEcrKeyViaEcrOnly"
    actions   = ["kms:Encrypt", "kms:GenerateDataKey", "kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ecr.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "ci_ecr_push" {
  name   = "ecr-push"
  role   = aws_iam_role.ci_ecr_push.id
  policy = data.aws_iam_policy_document.ci_ecr_push.json
}

# --- Terraform state access (both Terraform roles) ------------------------------------
data "aws_iam_policy_document" "state" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [var.state_bucket_arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.state_bucket_arn}/${var.state_key_prefix}*"]
  }
  statement {
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
    resources = [var.state_kms_key_arn]
  }
}

# --- tf-plan --------------------------------------------------------------------------
resource "aws_iam_role" "tf_plan" {
  name                 = "${var.name}-tf-plan"
  path                 = var.iam_path
  assume_role_policy   = data.aws_iam_policy_document.trust["tf-plan"].json
  max_session_duration = 3600
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "tf_plan_readonly" {
  role       = aws_iam_role.tf_plan.name
  policy_arn = "arn:${local.p}:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess can read secret *metadata*; make sure plan can never read values.
data "aws_iam_policy_document" "tf_plan_guard" {
  source_policy_documents = [data.aws_iam_policy_document.state.json]
  statement {
    sid       = "NeverReadSecretValues"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue", "ssm:GetParameter*", "kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"] # state decryption only
    }
  }
}

resource "aws_iam_role_policy" "tf_plan" {
  name   = "state-and-guards"
  role   = aws_iam_role.tf_plan.id
  policy = data.aws_iam_policy_document.tf_plan_guard.json
}

# --- Permissions boundary for every role Terraform creates --------------------------
# Max permissions any created role can ever have: no IAM/Organizations/account
# changes, no leaving the region, no disabling CloudTrail.
data "aws_iam_policy_document" "boundary" {
  statement {
    sid = "AllowWorkloadServices"
    actions = [
      "ec2:*", "eks:*", "eks-auth:*", "elasticloadbalancing:*", "autoscaling:*", "ecr:*", "logs:*", "cloudwatch:*",
      "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant",
      "kms:ListGrants", "kms:RevokeGrant", "secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret",
      "acm:DescribeCertificate", "acm:ListCertificates", "wafv2:*", "waf-regional:*", "shield:*",
      "cognito-idp:DescribeUserPoolClient", "sts:AssumeRole", "sts:TagSession",
      "iam:CreateServiceLinkedRole", "iam:GetServerCertificate", "iam:ListServerCertificates",
      "tag:GetResources",
    ]
    resources = ["*"]
  }
  statement {
    sid         = "DenyOutsideRegion"
    effect      = "Deny"
    not_actions = ["iam:*", "sts:*", "cloudfront:*", "route53:*", "waf:*", "support:*"]
    resources   = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }
  statement {
    sid       = "DenyAuditTampering"
    effect    = "Deny"
    actions   = ["cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail", "guardduty:Delete*", "guardduty:Disassociate*"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "boundary" {
  name        = "${var.name}-workload-boundary"
  path        = var.iam_path
  description = "Permissions boundary required on every IAM role created by tf-apply"
  policy      = data.aws_iam_policy_document.boundary.json
  tags        = var.tags
}

# --- tf-apply -------------------------------------------------------------------------
resource "aws_iam_role" "tf_apply" {
  name                 = "${var.name}-tf-apply"
  path                 = var.iam_path
  assume_role_policy   = data.aws_iam_policy_document.trust["tf-apply"].json
  max_session_duration = 3600 * 2
  tags                 = var.tags
}

data "aws_iam_policy_document" "tf_apply" {
  source_policy_documents = [data.aws_iam_policy_document.state.json]

  statement {
    sid = "ManageDesignedServices"
    actions = [
      "ec2:*", "eks:*", "ecr:*", "kms:*", "logs:*", "cloudwatch:*", "events:*", "sns:*",
      "secretsmanager:CreateSecret", "secretsmanager:DeleteSecret", "secretsmanager:DescribeSecret",
      "secretsmanager:TagResource", "secretsmanager:UntagResource", "secretsmanager:UpdateSecret",
      "secretsmanager:PutResourcePolicy", "secretsmanager:GetResourcePolicy", "secretsmanager:DeleteResourcePolicy",
      "secretsmanager:ValidateResourcePolicy", "secretsmanager:ListSecrets",
      "elasticloadbalancing:Describe*", "acm:Describe*", "acm:List*", "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }

  # Read IAM anywhere; write IAM only under our path.
  statement {
    sid       = "IamRead"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }

  # Creating or changing a role is allowed ONLY with the boundary attached.
  statement {
    sid       = "IamRolesOnlyWithBoundary"
    actions   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy"]
    resources = ["${local.role_arn_prefix}*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.boundary.arn]
    }
  }

  statement {
    sid = "IamManageOwnPath"
    actions = [
      "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy", "iam:TagRole", "iam:UntagRole",
      "iam:CreatePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:DeletePolicyVersion",
      "iam:TagPolicy", "iam:UntagPolicy",
    ]
    resources = [
      "${local.role_arn_prefix}*",
      "arn:${local.p}:iam::${local.account}:policy${var.iam_path}*",
    ]
  }

  # PassRole only for our own roles and only to the services that use them.
  statement {
    sid       = "PassOwnRolesToDesignedServices"
    actions   = ["iam:PassRole"]
    resources = ["${local.role_arn_prefix}*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["eks.amazonaws.com", "ec2.amazonaws.com", "vpc-flow-logs.amazonaws.com", "pods.eks.amazonaws.com"]
    }
  }

  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "iam:AWSServiceName"
      values   = ["eks.amazonaws.com", "eks-nodegroup.amazonaws.com", "elasticloadbalancing.amazonaws.com", "autoscaling.amazonaws.com"]
    }
  }

  # The boundary itself and the Terraform roles are never modifiable by tf-apply.
  statement {
    sid       = "ProtectBoundaryAndSelf"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary", "iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:SetDefaultPolicyVersion"]
    resources = [aws_iam_policy.boundary.arn]
  }

  statement {
    sid       = "NoSelfEscalation"
    effect    = "Deny"
    actions   = ["iam:*"]
    resources = ["${local.role_arn_prefix}${var.name}-tf-*"]
  }

  statement {
    sid       = "NeverReadSecretValues"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "tf_apply" {
  name   = "${var.name}-tf-apply"
  path   = var.iam_path
  policy = data.aws_iam_policy_document.tf_apply.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "tf_apply" {
  role       = aws_iam_role.tf_apply.name
  policy_arn = aws_iam_policy.tf_apply.arn
}
