# ECR repositories: immutable tags, scan on push, KMS encryption, lifecycle.
# Optional pull-through cache rules mirror upstream registries (the AWS
# equivalent of the local k3d-mirror-* caches).
resource "aws_ecr_repository" "this" {
  for_each             = toset(var.repositories)
  name                 = "${var.prefix}/${each.value}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 14 days"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 14 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last ${var.keep_images} sha-* images"
        selection    = { tagStatus = "tagged", tagPrefixList = ["sha-"], countType = "imageCountMoreThan", countNumber = var.keep_images }
        action       = { type = "expire" }
      },
    ]
  })
}

# quay.io needs no credentials. ghcr.io / Docker Hub need a Secrets Manager
# secret named ecr-pullthroughcache/<name> whose VALUE is set out of band.
resource "aws_ecr_pull_through_cache_rule" "this" {
  for_each              = var.pull_through_cache
  ecr_repository_prefix = each.key
  upstream_registry_url = each.value.upstream
  credential_arn        = each.value.credential_arn
}
