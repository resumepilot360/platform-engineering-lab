# Account bootstrap: applied ONCE per AWS account by a human administrator
# (local state, then optionally migrated into the bucket it creates):
#   - S3 state bucket (versioned, SSE-KMS, TLS-only, public access blocked)
#   - GitHub OIDC provider + ci-ecr-push / tf-plan / tf-apply roles
#   - the permissions boundary every environment-created role must carry
# Environment roots (environments/*) are then planned/applied only by CI roles.
provider "aws" {
  region = var.region
  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  tags = {
    project    = "platform-lab"
    managed-by = "terraform"
    stack      = "bootstrap"
  }
  bucket = "${var.name}-tfstate-${data.aws_caller_identity.current.account_id}"
}

module "state_key" {
  source      = "../modules/kms-key"
  alias       = "${var.name}-tfstate"
  description = "Terraform state encryption"
  tags        = local.tags
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = module.state_key.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json
}

module "github_oidc" {
  source                = "../modules/github-oidc"
  name                  = var.name
  github_repository     = var.github_repository
  create_provider       = var.create_github_oidc_provider
  region                = var.region
  ecr_repository_prefix = var.name
  state_bucket_arn      = aws_s3_bucket.state.arn
  state_key_prefix      = "${var.name}/"
  state_kms_key_arn     = module.state_key.arn
  tags                  = local.tags
}
