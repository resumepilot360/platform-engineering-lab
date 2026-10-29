module "env" {
  source = "../../modules/environment"

  environment             = var.environment
  vpc_cidr                = var.vpc_cidr
  az_count                = var.az_count
  single_nat_gateway      = var.single_nat_gateway
  interface_endpoints     = var.interface_endpoints
  kubernetes_version      = var.kubernetes_version
  api_public_access_cidrs = var.api_public_access_cidrs
  node_instance_types     = var.node_instance_types
  node_capacity_type      = var.node_capacity_type
  node_min                = var.node_min
  node_desired            = var.node_desired
  node_max                = var.node_max
  log_retention_days      = var.log_retention_days

  kms_admin_arns                 = compact([var.terraform_apply_role_arn])
  persona_trusted_principal_arns = var.persona_trusted_principal_arns
  breakglass_principal_arns      = var.breakglass_principal_arns
  terraform_apply_role_arn       = var.terraform_apply_role_arn
  permissions_boundary           = var.permissions_boundary
  ecr_pull_through_cache         = { quay = { upstream = "quay.io" } }
  alert_emails                   = var.alert_emails
}

# Stage 2 (after the cluster exists): Kubernetes bootstrap via Helm.
module "cluster_bootstrap" {
  count  = var.enable_cluster_bootstrap ? 1 : 0
  source = "../../modules/cluster-bootstrap"

  cluster_name         = module.env.cluster_name
  cluster_arn          = module.env.cluster_arn
  region               = var.region
  vpc_id               = module.env.vpc_id
  gitops_repo_url      = var.gitops_repo_url
  gitops_path          = var.gitops_path
  permissions_boundary = var.permissions_boundary
}
