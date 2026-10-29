output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_arn" {
  value = module.eks.cluster_arn
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_ca_data" {
  value = module.eks.cluster_ca_data
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "persona_role_arns" {
  value = module.access.persona_role_arns
}

output "breakglass_role_arn" {
  value = module.access.breakglass_role_arn
}

output "external_secrets_role_arn" {
  value = module.eso_role.arn
}

output "secret_arns" {
  value = module.secrets.secret_arns
}

output "alerts_topic_arn" {
  value = module.observability.alerts_topic_arn
}
