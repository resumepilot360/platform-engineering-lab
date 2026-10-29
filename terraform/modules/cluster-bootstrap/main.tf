# Day-0 Kubernetes bootstrap, the AWS equivalent of scripts/cluster-up.sh's
# final steps: AWS Load Balancer Controller (with Pod Identity) and Argo CD +
# the root app-of-apps. After this, Argo CD owns all Kubernetes config
# (ADR-0009); Terraform never manages namespaces, RBAC or workloads.
module "lbc_role" {
  source               = "../pod-identity-role"
  name                 = "${var.cluster_name}-aws-lbc"
  iam_path             = var.iam_path
  permissions_boundary = var.permissions_boundary
  inline_policy        = file("${path.module}/files/aws-lbc-iam-policy.json") # upstream v3.6.2, unmodified
  cluster_name         = var.cluster_name
  cluster_arn          = var.cluster_arn
  namespace            = "kube-system"
  service_account      = "aws-load-balancer-controller"
  tags                 = var.tags
}

resource "helm_release" "lbc" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.lbc_chart_version
  wait       = true
  values = [yamlencode({
    clusterName    = var.cluster_name
    region         = var.region
    vpcId          = var.vpc_id
    replicaCount   = 2
    serviceAccount = { create = true, name = "aws-load-balancer-controller" }
    resources      = { requests = { cpu = "50m", memory = "96Mi" }, limits = { memory = "256Mi" } }
  })]
  depends_on = [module.lbc_role]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  wait             = true
  # Same baseline as the lab (gitops/bootstrap/argocd/values.yaml), minus the
  # local-only Traefik ingress; exposure on AWS is an internal ALB via LBC.
  values = [yamlencode({
    dex           = { enabled = false }
    notifications = { enabled = false }
    configs = {
      params = { "server.insecure" = true, "controller.sync.timeout.seconds" = "600" }
      cm     = { "admin.enabled" = false, "exec.enabled" = false, "timeout.reconciliation" = "120s" }
      rbac = {
        "policy.default" = "role:readonly"
        "policy.csv"     = <<-CSV
          p, role:developer, applications, get,  demo/*,        allow
          p, role:developer, applications, sync, demo/demo-dev, allow
          g, lab:developers,      role:developer
          g, lab:auditors,        role:readonly
          g, lab:platform-admins, role:admin
        CSV
      }
    }
  })]
  depends_on = [helm_release.lbc]
}

resource "helm_release" "root_app" {
  name       = "argocd-root"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version
  values = [yamlencode({
    applications = {
      root = {
        namespace = "argocd"
        project   = "default"
        source = {
          repoURL        = var.gitops_repo_url
          targetRevision = var.gitops_revision
          path           = var.gitops_path
        }
        destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
        syncPolicy  = { automated = { prune = true, selfHeal = true } }
      }
    }
  })]
  depends_on = [helm_release.argocd]
}
