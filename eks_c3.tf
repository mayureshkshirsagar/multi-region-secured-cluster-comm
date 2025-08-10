module "eks_c3" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  providers = { aws = aws.c1 }

  cluster_name    = var.c3_cluster_name
  cluster_version = "1.29"

  cluster_endpoint_public_access  = false
  cluster_endpoint_private_access = true

  vpc_id                   = module.vpc_c1.vpc_id
  subnet_ids               = module.vpc_c1.private_subnets
  control_plane_subnet_ids = module.vpc_c1.private_subnets

  enable_irsa = true

  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 3
      desired_size   = 2
      subnet_ids     = module.vpc_c1.private_subnets
    }
  }

  tags = merge(var.tags, { Component = "c3" })
}

output "c3_cluster_name" { value = module.eks_c3.cluster_name }
output "c3_cluster_endpoint" { value = module.eks_c3.cluster_endpoint }
output "c3_node_security_group_id" { value = module.eks_c3.node_security_group_id }
output "c3_cluster_primary_security_group_id" { value = module.eks_c3.cluster_primary_security_group_id }

