terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.71"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
  }
}

provider "aws" {
  region = var.region
  # Refuse to run against any account other than the one this environment is for.
  allowed_account_ids = [var.aws_account_id]
  default_tags {
    tags = { project = "platform-lab", environment = var.environment, managed-by = "terraform" }
  }
}

# Short-lived token from the caller's own AWS identity (the tf-apply role in CI);
# no kubeconfig or static credentials. Only used when enable_cluster_bootstrap = true.
provider "helm" {
  kubernetes = {
    host                   = module.env.cluster_endpoint
    cluster_ca_certificate = base64decode(module.env.cluster_ca_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.env.cluster_name, "--region", var.region]
    }
  }
}
