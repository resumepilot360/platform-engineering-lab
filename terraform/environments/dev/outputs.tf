# Identifiers only: no secret values are ever produced by this configuration.
output "cluster_name" {
  value = module.env.cluster_name
}

output "cluster_endpoint" {
  value = module.env.cluster_endpoint
}

output "ecr_repository_urls" {
  value = module.env.ecr_repository_urls
}

output "persona_role_arns" {
  value = module.env.persona_role_arns
}

output "breakglass_role_arn" {
  value = module.env.breakglass_role_arn
}

output "external_secrets_role_arn" {
  value = module.env.external_secrets_role_arn
}

output "alerts_topic_arn" {
  value = module.env.alerts_topic_arn
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.env.cluster_name} --region ${var.region} --role-arn <persona role ARN>"
}
