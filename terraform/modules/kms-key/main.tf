# One customer-managed KMS key with rotation and an explicit key policy:
# administrators manage the key; only listed principals/services may use it.
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_root = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
}

data "aws_iam_policy_document" "this" {
  # Account root retains control so the key can never become unmanageable.
  statement {
    sid       = "AccountRootFullAccess"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.account_root]
    }
  }

  dynamic "statement" {
    for_each = length(var.admin_principal_arns) > 0 ? [1] : []
    content {
      sid = "KeyAdministrators"
      actions = [
        "kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*", "kms:Put*", "kms:Update*",
        "kms:Revoke*", "kms:Disable*", "kms:Get*", "kms:Delete*", "kms:TagResource",
        "kms:UntagResource", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion",
      ]
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = var.admin_principal_arns
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.user_principal_arns) > 0 ? [1] : []
    content {
      sid       = "KeyUsers"
      actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = var.user_principal_arns
      }
      dynamic "condition" {
        for_each = length(var.via_services) > 0 ? [1] : []
        content {
          test     = "StringEquals"
          variable = "kms:ViaService"
          values   = var.via_services
        }
      }
    }
  }

  # Lets key users (e.g. the Auto Scaling service-linked role for encrypted EBS)
  # create grants for AWS resources only.
  dynamic "statement" {
    for_each = var.allow_grants && length(var.user_principal_arns) > 0 ? [1] : []
    content {
      sid       = "KeyUsersGrantsForAwsResources"
      actions   = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = var.user_principal_arns
      }
      condition {
        test     = "Bool"
        variable = "kms:GrantIsForAWSResource"
        values   = ["true"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.service_principals
    content {
      sid       = "Service${replace(title(replace(statement.value, ".", " ")), " ", "")}"
      actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
      resources = ["*"]
      principals {
        type        = "Service"
        identifiers = [statement.value]
      }
      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }
}

resource "aws_kms_key" "this" {
  description             = var.description
  enable_key_rotation     = true
  rotation_period_in_days = 365
  deletion_window_in_days = var.deletion_window_in_days
  policy                  = data.aws_iam_policy_document.this.json
  tags                    = var.tags
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.alias}"
  target_key_id = aws_kms_key.this.key_id
}
