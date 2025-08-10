# IRSA for AWS Load Balancer Controller in C2
module "c2_lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  providers = { aws = aws.c2 }

  role_name_prefix = "${var.project_name}-c2-lbc-"

  oidc_providers = {
    c2 = {
      provider_arn               = module.eks_c2.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  role_policy_arns = {
    lbc = aws_iam_policy.c2_lbc.arn
  }

  tags = merge(var.tags, { Component = "c2", App = "alb-controller" })
}

resource "aws_iam_policy" "c2_lbc" {
  provider = aws.c2
  name     = "${var.project_name}-c2-lbc-policy"
  policy   = file("extras/alb-controller/iam_policy.json")
}

# Namespace and SA
resource "kubernetes_namespace" "lbc" {
  provider = kubernetes.c2
  metadata { name = "kube-system" }
}

resource "kubernetes_service_account" "lbc" {
  provider = kubernetes.c2
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = module.c2_lb_controller_irsa.iam_role_arn
    }
  }
}

# Helm install
resource "helm_release" "lbc" {
  provider   = helm.c2
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.8.1"

  set {
    name  = "clusterName"
    value = var.c2_cluster_name
  }
  set {
    name  = "region"
    value = var.region_b
  }
  set {
    name  = "serviceAccount.create"
    value = "false"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  depends_on = [kubernetes_service_account.lbc]
}
