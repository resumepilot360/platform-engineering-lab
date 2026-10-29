# Composition of one environment (dev, staging): keys, network, EKS, access,
# registry, secrets, External Secrets identity, alerting. Kubernetes bootstrap
# (Helm) is a separate module called from the root, because the Helm provider
# is configured from this module's cluster outputs.
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  name    = "${var.project}-${var.environment}"
  account = data.aws_caller_identity.current.account_id
  p       = data.aws_partition.current.partition
  region  = data.aws_region.current.region
  tags    = merge(var.tags, { project = var.project, environment = var.environment, managed-by = "terraform" })
  asg_slr = "arn:${local.p}:iam::${local.account}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"
}

# --- KMS: one key per purpose -------------------------------------------------------
module "kms_eks" {
  source               = "../kms-key"
  alias                = "${local.name}-eks-secrets"
  description          = "${local.name}: Kubernetes Secret envelope encryption"
  admin_principal_arns = var.kms_admin_arns
  tags                 = local.tags
}

module "kms_ebs" {
  source               = "../kms-key"
  alias                = "${local.name}-ebs"
  description          = "${local.name}: EBS volumes (nodes, PVs)"
  admin_principal_arns = var.kms_admin_arns
  user_principal_arns  = [local.asg_slr]
  allow_grants         = true
  tags                 = local.tags
}

module "kms_logs" {
  source               = "../kms-key"
  alias                = "${local.name}-logs"
  description          = "${local.name}: CloudWatch Logs and alert topic"
  admin_principal_arns = var.kms_admin_arns
  service_principals   = ["logs.${local.region}.amazonaws.com", "events.amazonaws.com"]
  tags                 = local.tags
}

module "kms_ecr" {
  source               = "../kms-key"
  alias                = "${local.name}-ecr"
  description          = "${local.name}: ECR images"
  admin_principal_arns = var.kms_admin_arns
  tags                 = local.tags
}

module "kms_secrets" {
  source               = "../kms-key"
  alias                = "${local.name}-secrets"
  description          = "${local.name}: Secrets Manager (use: External Secrets only)"
  admin_principal_arns = var.kms_admin_arns
  user_principal_arns  = [module.eso_role.arn]
  via_services         = ["secretsmanager.${local.region}.amazonaws.com"]
  tags                 = local.tags
}

# --- Network + EKS --------------------------------------------------------------------
module "network" {
  source               = "../network"
  name                 = local.name
  cidr                 = var.vpc_cidr
  az_count             = var.az_count
  single_nat_gateway   = var.single_nat_gateway
  interface_endpoints  = var.interface_endpoints
  logs_kms_key_arn     = module.kms_logs.arn
  log_retention_days   = var.log_retention_days
  permissions_boundary = var.permissions_boundary
  tags                 = local.tags
}

module "eks" {
  source               = "../eks"
  name                 = local.name
  kubernetes_version   = var.kubernetes_version
  private_subnet_ids   = module.network.private_subnet_ids
  public_access_cidrs  = var.api_public_access_cidrs
  secrets_kms_key_arn  = module.kms_eks.arn
  ebs_kms_key_arn      = module.kms_ebs.arn
  logs_kms_key_arn     = module.kms_logs.arn
  log_retention_days   = var.log_retention_days
  instance_types       = var.node_instance_types
  capacity_type        = var.node_capacity_type
  node_min             = var.node_min
  node_desired         = var.node_desired
  node_max             = var.node_max
  permissions_boundary = var.permissions_boundary
  tags                 = local.tags
}

module "access" {
  source                    = "../eks-access"
  cluster_name              = module.eks.cluster_name
  trusted_principal_arns    = var.persona_trusted_principal_arns
  breakglass_principal_arns = var.breakglass_principal_arns
  terraform_role_arn        = var.terraform_apply_role_arn
  permissions_boundary      = var.permissions_boundary
  tags                      = local.tags
}

# --- Registry, secrets, External Secrets identity ---------------------------------------
module "ecr" {
  source             = "../ecr"
  prefix             = var.project
  repositories       = var.ecr_repositories
  kms_key_arn        = module.kms_ecr.arn
  pull_through_cache = var.ecr_pull_through_cache
  tags               = local.tags
}

data "aws_iam_policy_document" "eso" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["arn:${local.p}:secretsmanager:${local.region}:${local.account}:secret:${var.environment}/*"]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${local.region}.amazonaws.com"]
    }
  }
}

module "eso_role" {
  source               = "../pod-identity-role"
  name                 = "${local.name}-external-secrets"
  permissions_boundary = var.permissions_boundary
  inline_policy        = data.aws_iam_policy_document.eso.json
  cluster_name         = module.eks.cluster_name
  cluster_arn          = module.eks.cluster_arn
  namespace            = "external-secrets"
  service_account      = "external-secrets"
  tags                 = local.tags
}

module "secrets" {
  source           = "../secrets"
  environment      = var.environment
  secret_names     = var.secret_names
  kms_key_arn      = module.kms_secrets.arn
  reader_role_arns = [module.eso_role.arn, module.access.breakglass_role_arn]
  tags             = local.tags
}

module "observability" {
  source                      = "../observability"
  name                        = local.name
  kms_key_arn                 = module.kms_logs.arn
  breakglass_role_arn         = module.access.breakglass_role_arn
  expected_secret_reader_arns = [module.eso_role.arn]
  alert_emails                = var.alert_emails
  tags                        = local.tags
}
