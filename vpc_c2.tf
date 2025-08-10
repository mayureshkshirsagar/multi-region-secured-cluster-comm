module "vpc_c2" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.5"

  providers = { aws = aws.c2 }

  name = "${var.project_name}-c2"
  cidr = var.c2_vpc_cidr

  azs = slice(data.aws_availability_zones.c2.names, 0, 3)

  private_subnets = [for i, az in slice(data.aws_availability_zones.c2.names, 0, 3) : cidrsubnet(var.c2_vpc_cidr, 4, i)]
  public_subnets  = [for i, az in slice(data.aws_availability_zones.c2.names, 0, 3) : cidrsubnet(var.c2_vpc_cidr, 4, i + 8)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  private_subnet_tags = {
    Tier = "private"
  }
  public_subnet_tags = {
    Tier = "public"
  }

  tags = merge(var.tags, { Component = "c2" })
}

data "aws_availability_zones" "c2" { provider = aws.c2 }
output "c2_vpc_id" { value = module.vpc_c2.vpc_id }
