variable "region_a" {
  type    = string
  default = "us-east-1"
}

variable "region_b" {
  type    = string
  default = "us-west-2"
}

provider "aws" {
  alias  = "c1"
  region = var.region_a
}

provider "aws" {
  alias  = "c2"
  region = var.region_b
}

data "aws_caller_identity" "current" {
  provider = aws.c1
}

data "aws_partition" "current" {
  provider = aws.c1
}

output "region_a" { value = var.region_a }
output "region_b" { value = var.region_b }
