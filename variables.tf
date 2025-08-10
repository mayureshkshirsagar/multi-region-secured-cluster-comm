variable "project_name" {
  type    = string
  default = "multi-region-secured-comm"
}

variable "c1_cluster_name" {
  type    = string
  default = "c1-eks"
}

variable "c2_cluster_name" {
  type    = string
  default = "c2-eks"
}

variable "c3_cluster_name" {
  type    = string
  default = "c3-eks"
}

variable "c1_vpc_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "c2_vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "create_bastion_instances" {
  description = "Whether to create an EC2 bastion in each VPC with private access to the EKS API"
  type        = bool
  default     = false
}

variable "bastion_instance_type" {
  description = "EC2 instance type for bastion instances"
  type        = string
  default     = "t3.micro"
}

variable "bastion_associate_public_ip" {
  description = "Associate a public IP to bastion instances (for troubleshooting only). Default false."
  type        = bool
  default     = false
}

variable "bastion_ssh_allowed_cidrs" {
  description = "CIDR blocks allowed to SSH to bastions when bastion_associate_public_ip is true"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  type = map(string)
  default = {
    ManagedBy = "terraform"
  }
}
