module "vpc_c1" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.5"

  providers = { aws = aws.c1 }

  name = "${var.project_name}-c1"
  cidr = var.c1_vpc_cidr

  azs = slice(data.aws_availability_zones.c1.names, 0, 3)

  private_subnets = [for i, az in slice(data.aws_availability_zones.c1.names, 0, 3) : cidrsubnet(var.c1_vpc_cidr, 4, i)]
  public_subnets  = [for i, az in slice(data.aws_availability_zones.c1.names, 0, 3) : cidrsubnet(var.c1_vpc_cidr, 4, i + 8)]

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

  tags = merge(var.tags, { Component = "c1" })
}

data "aws_availability_zones" "c1" { provider = aws.c1 }
output "c1_vpc_id" { value = module.vpc_c1.vpc_id }
