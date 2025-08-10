terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0.0"
    }
  }
}

variable "region_a" {
  type    = string
  default = "us-east-1"
}
variable "region_b" {
  type    = string
  default = "us-west-2"
}

# EKS cluster name in region_b (C2) for tag scoping
variable "c2_cluster_name" {
  type    = string
  default = "c2-eks"
}

variable "c1_node_security_group_id" {
  type = string
}

provider "aws" {
  alias  = "c1"
  region = var.region_a
}

provider "aws" {
  alias  = "c2"
  region = var.region_b
}
# Import VPCs created in root by Name tag

data "aws_vpc" "c1" {
  provider = aws.c1
  filter {
    name   = "tag:Name"
    values = ["multi-region-secured-comm-c1"]
  }
}

data "aws_vpc" "c2" {
  provider = aws.c2
  filter {
    name   = "tag:Name"
    values = ["multi-region-secured-comm-c2"]
  }
}

data "aws_subnets" "c1_private" {
  provider = aws.c1
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.c1.id]
  }
  filter {
    name   = "tag:Tier"
    values = ["private"]
  }
}

data "aws_subnets" "c2_private" {
  provider = aws.c2
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.c2.id]
  }
  filter {
    name   = "tag:Tier"
    values = ["private"]
  }
}

# Discover the internal NLB created by the K8s Service (must exist before apply)
# For AWS Load Balancer Controller, tags include:
# - service.k8s.aws/stack = "<namespace>/<service>"
# - elbv2.k8s.aws/cluster = "<cluster-name>"
variable "k8s_service_tag" {
  type    = string
  default = "default/echo-lb"
}

data "aws_lb" "c2_nlb" {
  provider = aws.c2
  tags = {
    "service.k8s.aws/stack" = var.k8s_service_tag
    "elbv2.k8s.aws/cluster" = var.c2_cluster_name
  }
}

# Endpoint Service in C2 that exposes the NLB via PrivateLink
resource "aws_vpc_endpoint_service" "c2_service" {
  provider = aws.c2

  acceptance_required = false

  supported_regions = [var.region_a, var.region_b]

  network_load_balancer_arns = [data.aws_lb.c2_nlb.arn]

  allowed_principals = [
    "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.c1.account_id}:root"
  ]
}

# Allow some propagation time so the service name is discoverable cross-region
resource "time_sleep" "wait_service_propagation" {
  depends_on      = [aws_vpc_endpoint_service.c2_service]
  create_duration = "180s"
}

data "aws_caller_identity" "c1" { provider = aws.c1 }

data "aws_partition" "current" { provider = aws.c1 }

# Security group for the Interface Endpoint in C1: allow inbound only from C1 node SG to port 80
variable "c1_cluster_name" {
  type    = string
  default = "c1-eks"
}

data "aws_security_groups" "c1_node_sg" {
  provider = aws.c1
  filter {
    name   = "tag:kubernetes.io/cluster/${var.c1_cluster_name}"
    values = ["owned"]
  }
}

resource "aws_security_group" "c1_interface_ep" {
  provider    = aws.c1
  name        = "c1-interface-endpoint-sg"
  description = "Allow only C1 node SG to access the Interface Endpoint"
  vpc_id      = data.aws_vpc.c1.id
}

resource "aws_vpc_security_group_egress_rule" "c1_ep_egress_all" {
  provider          = aws.c1
  security_group_id = aws_security_group.c1_interface_ep.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "c1_ep_ingress_nodes_http" {
  provider                     = aws.c1
  security_group_id            = aws_security_group.c1_interface_ep.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = element(data.aws_security_groups.c1_node_sg.ids, 0)
}

resource "aws_vpc_security_group_ingress_rule" "c1_ep_ingress_c1_nodes_tcp" {
  provider                     = aws.c1
  security_group_id            = aws_security_group.c1_interface_ep.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = var.c1_node_security_group_id
}
# Interface Endpoint in C1 that connects to the Endpoint Service in C2 (cross-region)
resource "aws_vpc_endpoint" "c1_interface" {
  provider            = aws.c1
  service_region      = var.region_b
  vpc_id              = data.aws_vpc.c1.id
  service_name        = aws_vpc_endpoint_service.c2_service.service_name
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.aws_subnets.c1_private.ids
  security_group_ids  = [aws_security_group.c1_interface_ep.id]
  private_dns_enabled = false

  dns_options { dns_record_ip_type = "ipv4" }

  depends_on = [time_sleep.wait_service_propagation]
}
