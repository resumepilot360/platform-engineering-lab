# Secrets Manager secret CONTAINERS only. Terraform never writes secret values
# (no aws_secretsmanager_secret_version): values would land in state. Values
# are set out of band or by rotation (docs/secrets-model.md §5).
#
# Resource policy: only the environment's ESO role (and break-glass) may read.
data "aws_caller_identity" "current" {}

resource "aws_secretsmanager_secret" "this" {
  for_each                = toset(var.secret_names)
  name                    = "${var.environment}/${each.value}"
  description             = "Value managed out of band; read by External Secrets in ${var.environment}."
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.recovery_window_in_days
  tags                    = merge(var.tags, { environment = var.environment })
}

data "aws_iam_policy_document" "this" {
  for_each = aws_secretsmanager_secret.this

  statement {
    sid       = "DenyReadExceptReaders"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotLike"
      variable = "aws:PrincipalArn"
      values   = var.reader_role_arns
    }
  }

  statement {
    sid       = "AllowReaders"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = var.reader_role_arns
    }
  }
}

resource "aws_secretsmanager_secret_policy" "this" {
  for_each            = aws_secretsmanager_secret.this
  secret_arn          = each.value.arn
  policy              = data.aws_iam_policy_document.this[each.key].json
  block_public_policy = true
}
