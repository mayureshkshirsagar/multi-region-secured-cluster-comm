locals {
  c1_private_subnet_id = try(element(module.vpc_c1.private_subnets, 0), null)
  c2_private_subnet_id = try(element(module.vpc_c2.private_subnets, 0), null)
  c1_public_subnet_id  = try(element(module.vpc_c1.public_subnets, 0), null)
  c2_public_subnet_id  = try(element(module.vpc_c2.public_subnets, 0), null)

  c1_bastion_subnet_id = var.bastion_associate_public_ip ? local.c1_public_subnet_id : local.c1_private_subnet_id
  c2_bastion_subnet_id = var.bastion_associate_public_ip ? local.c2_public_subnet_id : local.c2_private_subnet_id
}

# Optional SSH key for bastions (used only when public IP is associated)
resource "tls_private_key" "bastion" {
  count     = var.bastion_associate_public_ip ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "c1_bastion" {
  count      = var.bastion_associate_public_ip ? 1 : 0
  provider   = aws.c1
  key_name   = "${var.project_name}-c1-bastion-key"
  public_key = tls_private_key.bastion[0].public_key_openssh
  tags       = merge(var.tags, { Component = "c1", Role = "bastion" })
}

resource "aws_key_pair" "c2_bastion" {
  count      = var.bastion_associate_public_ip ? 1 : 0
  provider   = aws.c2
  key_name   = "${var.project_name}-c2-bastion-key"
  public_key = tls_private_key.bastion[0].public_key_openssh
  tags       = merge(var.tags, { Component = "c2", Role = "bastion" })
}

# ---------- C1 Bastion ----------

data "aws_ami" "al2023_c1" {
  count    = var.create_bastion_instances ? 1 : 0
  provider = aws.c1
  owners   = ["137112412989"] # Amazon
  filter {
    name   = "name"
    values = ["al2023-ami-*-kernel-6.1-x86_64"]
  }
  most_recent = true
}

resource "aws_iam_role" "c1_bastion" {
  count    = var.create_bastion_instances ? 1 : 0
  name     = "${var.project_name}-c1-bastion-role"
  provider = aws.c1
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = merge(var.tags, { Component = "c1", Role = "bastion" })
}

resource "aws_iam_role_policy_attachment" "c1_bastion_ssm" {
  count      = var.create_bastion_instances ? 1 : 0
  provider   = aws.c1
  role       = aws_iam_role.c1_bastion[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "c1_bastion" {
  count    = var.create_bastion_instances ? 1 : 0
  provider = aws.c1
  name     = "${var.project_name}-c1-bastion-profile"
  role     = aws_iam_role.c1_bastion[0].name
}

resource "aws_security_group" "c1_bastion" {
  count       = var.create_bastion_instances ? 1 : 0
  provider    = aws.c1
  name        = "${var.project_name}-c1-bastion-sg"
  description = "Bastion SG (SSM + optional SSH)"
  vpc_id      = module.vpc_c1.vpc_id

  dynamic "ingress" {
    for_each = var.bastion_associate_public_ip ? toset(var.bastion_ssh_allowed_cidrs) : []
    content {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
      description = "SSH access"
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(var.tags, { Component = "c1", Role = "bastion" })
}

resource "aws_instance" "c1_bastion" {
  count                       = var.create_bastion_instances ? 1 : 0
  provider                    = aws.c1
  ami                         = data.aws_ami.al2023_c1[0].id
  instance_type               = var.bastion_instance_type
  subnet_id                   = local.c1_bastion_subnet_id
  vpc_security_group_ids      = [aws_security_group.c1_bastion[0].id]
  iam_instance_profile        = aws_iam_instance_profile.c1_bastion[0].name
  associate_public_ip_address = var.bastion_associate_public_ip
  key_name                    = can(aws_key_pair.c1_bastion[0].key_name) ? aws_key_pair.c1_bastion[0].key_name : null
  user_data                   = <<-EOT
#!/bin/bash
set -euo pipefail

# Base deps (avoid replacing curl to prevent conflicts)
(dnf -y install unzip tar gzip jq >/dev/null 2>&1 || true)

# Ensure SSM agent (dnf with allowerasing, then fallback to regional RPM)
if ! rpm -q amazon-ssm-agent >/dev/null 2>&1; then
  if dnf -y install --allowerasing amazon-ssm-agent >/dev/null 2>&1; then
    echo "amazon-ssm-agent installed via dnf"
  else
    ARCH=$(uname -m); PKG_ARCH="amd64"; [ "$ARCH" = "aarch64" ] && PKG_ARCH="arm64"
    REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region || echo "${var.region_a}")
    URL_PRIMARY="https://s3.$${REGION}.amazonaws.com/amazon-ssm-$${REGION}/latest/linux_$${PKG_ARCH}/amazon-ssm-agent.rpm"
    URL_FALLBACK="https://s3.amazonaws.com/amazon-ssm-$${REGION}/latest/linux_$${PKG_ARCH}/amazon-ssm-agent.rpm"
    curl -fsSL -o /tmp/amazon-ssm-agent.rpm "$${URL_PRIMARY}" || curl -fsSL -o /tmp/amazon-ssm-agent.rpm "$${URL_FALLBACK}"
    rpm -Uvh /tmp/amazon-ssm-agent.rpm >/dev/null 2>&1 || true
  fi
fi
systemctl enable --now amazon-ssm-agent || true

# Detect arch for kubectl/eksctl
ARCH=$(uname -m)
KUBECTL_ARCH="amd64"; [ "$ARCH" = "aarch64" ] && KUBECTL_ARCH="arm64"
EKSCTL_ARCH="$KUBECTL_ARCH"

# kubectl (pin to v1.29.7)
if ! command -v kubectl >/dev/null 2>&1; then
  KVER="v1.29.7"
  curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$${KVER}/bin/linux/$${KUBECTL_ARCH}/kubectl"
  chmod +x /usr/local/bin/kubectl
fi

# Helm (per official script)
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 /tmp/get_helm.sh
  /tmp/get_helm.sh >/dev/null 2>&1 || true
fi

# eksctl
if ! command -v eksctl >/dev/null 2>&1; then
  curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_$${EKSCTL_ARCH}.tar.gz" | tar xz -C /tmp
  install -m 0755 /tmp/eksctl /usr/local/bin/eksctl
fi
EOT
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  tags = merge(var.tags, { Name = "${var.project_name}-c1-bastion", Component = "c1", Role = "bastion" })

  depends_on = [
    aws_vpc_endpoint.c1_ssm,
    aws_vpc_endpoint.c1_ec2messages,
    aws_vpc_endpoint.c1_ssmmessages
  ]
}

# C1 SSM interface endpoints (to avoid dependency on NAT)
resource "aws_security_group" "c1_ssm_endpoints" {
  count       = var.create_bastion_instances ? 1 : 0
  provider    = aws.c1
  name        = "${var.project_name}-c1-ssm-endpoints-sg"
  description = "Allow HTTPS from VPC to SSM endpoints"
  vpc_id      = module.vpc_c1.vpc_id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.vpc_c1.vpc_cidr_block]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpc_endpoint" "c1_ssm" {
  count               = var.create_bastion_instances ? 1 : 0
  provider            = aws.c1
  vpc_id              = module.vpc_c1.vpc_id
  service_name        = "com.amazonaws.${var.region_a}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc_c1.private_subnets
  security_group_ids  = [aws_security_group.c1_ssm_endpoints[0].id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "c1_ec2messages" {
  count               = var.create_bastion_instances ? 1 : 0
  provider            = aws.c1
  vpc_id              = module.vpc_c1.vpc_id
  service_name        = "com.amazonaws.${var.region_a}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc_c1.private_subnets
  security_group_ids  = [aws_security_group.c1_ssm_endpoints[0].id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "c1_ssmmessages" {
  count               = var.create_bastion_instances ? 1 : 0
  provider            = aws.c1
  vpc_id              = module.vpc_c1.vpc_id
  service_name        = "com.amazonaws.${var.region_a}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc_c1.private_subnets
  security_group_ids  = [aws_security_group.c1_ssm_endpoints[0].id]
  private_dns_enabled = true
}

# ---------- C2 Bastion ----------

data "aws_ami" "al2023_c2" {
  count    = var.create_bastion_instances ? 1 : 0
  provider = aws.c2
  owners   = ["137112412989"] # Amazon
  filter {
    name   = "name"
    values = ["al2023-ami-*-kernel-6.1-x86_64"]
  }
  most_recent = true
}

resource "aws_iam_role" "c2_bastion" {
  count    = var.create_bastion_instances ? 1 : 0
  name     = "${var.project_name}-c2-bastion-role"
  provider = aws.c2
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = merge(var.tags, { Component = "c2", Role = "bastion" })
}

resource "aws_iam_role_policy_attachment" "c2_bastion_ssm" {
  count      = var.create_bastion_instances ? 1 : 0
  provider   = aws.c2
  role       = aws_iam_role.c2_bastion[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "c2_bastion" {
  count    = var.create_bastion_instances ? 1 : 0
  provider = aws.c2
  name     = "${var.project_name}-c2-bastion-profile"
  role     = aws_iam_role.c2_bastion[0].name
}

resource "aws_security_group" "c2_bastion" {
  count       = var.create_bastion_instances ? 1 : 0
  provider    = aws.c2
  name        = "${var.project_name}-c2-bastion-sg"
  description = "Bastion SG (SSM + optional SSH)"
  vpc_id      = module.vpc_c2.vpc_id

  dynamic "ingress" {
    for_each = var.bastion_associate_public_ip ? toset(var.bastion_ssh_allowed_cidrs) : []
    content {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
      description = "SSH access"
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(var.tags, { Component = "c2", Role = "bastion" })
}

resource "aws_instance" "c2_bastion" {
  count                       = var.create_bastion_instances ? 1 : 0
  provider                    = aws.c2
  ami                         = data.aws_ami.al2023_c2[0].id
  instance_type               = var.bastion_instance_type
  subnet_id                   = local.c2_bastion_subnet_id
  vpc_security_group_ids      = [aws_security_group.c2_bastion[0].id]
  iam_instance_profile        = aws_iam_instance_profile.c2_bastion[0].name
  associate_public_ip_address = var.bastion_associate_public_ip
  key_name                    = can(aws_key_pair.c2_bastion[0].key_name) ? aws_key_pair.c2_bastion[0].key_name : null
  user_data                   = <<-EOT
#!/bin/bash
set -euo pipefail

# Base deps (avoid replacing curl to prevent conflicts)
(dnf -y install unzip tar gzip jq >/dev/null 2>&1 || true)

# Ensure SSM agent (dnf with allowerasing, then fallback to regional RPM)
if ! rpm -q amazon-ssm-agent >/dev/null 2>&1; then
  if dnf -y install --allowerasing amazon-ssm-agent >/dev/null 2>&1; then
    echo "amazon-ssm-agent installed via dnf"
  else
    ARCH=$(uname -m); PKG_ARCH="amd64"; [ "$ARCH" = "aarch64" ] && PKG_ARCH="arm64"
    REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region || echo "${var.region_b}")
    URL_PRIMARY="https://s3.$${REGION}.amazonaws.com/amazon-ssm-$${REGION}/latest/linux_$${PKG_ARCH}/amazon-ssm-agent.rpm"
    URL_FALLBACK="https://s3.amazonaws.com/amazon-ssm-$${REGION}/latest/linux_$${PKG_ARCH}/amazon-ssm-agent.rpm"
    curl -fsSL -o /tmp/amazon-ssm-agent.rpm "$${URL_PRIMARY}" || curl -fsSL -o /tmp/amazon-ssm-agent.rpm "$${URL_FALLBACK}"
    rpm -Uvh /tmp/amazon-ssm-agent.rpm >/dev/null 2>&1 || true
  fi
fi
systemctl enable --now amazon-ssm-agent || true

# Detect arch for kubectl/eksctl
ARCH=$(uname -m)
KUBECTL_ARCH="amd64"; [ "$ARCH" = "aarch64" ] && KUBECTL_ARCH="arm64"
EKSCTL_ARCH="$KUBECTL_ARCH"

# kubectl (pin to v1.29.7)
if ! command -v kubectl >/dev/null 2>&1; then
  KVER="v1.29.7"
  curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$${KVER}/bin/linux/$${KUBECTL_ARCH}/kubectl"
  chmod +x /usr/local/bin/kubectl
fi

# Helm (per official script)
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 /tmp/get_helm.sh
  /tmp/get_helm.sh >/dev/null 2>&1 || true
fi

# eksctl
if ! command -v eksctl >/dev/null 2>&1; then
  curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_$${EKSCTL_ARCH}.tar.gz" | tar xz -C /tmp
  install -m 0755 /tmp/eksctl /usr/local/bin/eksctl
fi
EOT
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  tags = merge(var.tags, { Name = "${var.project_name}-c2-bastion", Component = "c2", Role = "bastion" })

  depends_on = [
    aws_vpc_endpoint.c2_ssm,
    aws_vpc_endpoint.c2_ec2messages,
    aws_vpc_endpoint.c2_ssmmessages
  ]
}

# C2 SSM interface endpoints
resource "aws_security_group" "c2_ssm_endpoints" {
  count       = var.create_bastion_instances ? 1 : 0
  provider    = aws.c2
  name        = "${var.project_name}-c2-ssm-endpoints-sg"
  description = "Allow HTTPS from VPC to SSM endpoints"
  vpc_id      = module.vpc_c2.vpc_id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.vpc_c2.vpc_cidr_block]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpc_endpoint" "c2_ssm" {
  count               = var.create_bastion_instances ? 1 : 0
  provider            = aws.c2
  vpc_id              = module.vpc_c2.vpc_id
  service_name        = "com.amazonaws.${var.region_b}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc_c2.private_subnets
  security_group_ids  = [aws_security_group.c2_ssm_endpoints[0].id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "c2_ec2messages" {
  count               = var.create_bastion_instances ? 1 : 0
  provider            = aws.c2
  vpc_id              = module.vpc_c2.vpc_id
  service_name        = "com.amazonaws.${var.region_b}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc_c2.private_subnets
  security_group_ids  = [aws_security_group.c2_ssm_endpoints[0].id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "c2_ssmmessages" {
  count               = var.create_bastion_instances ? 1 : 0
  provider            = aws.c2
  vpc_id              = module.vpc_c2.vpc_id
  service_name        = "com.amazonaws.${var.region_b}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc_c2.private_subnets
  security_group_ids  = [aws_security_group.c2_ssm_endpoints[0].id]
  private_dns_enabled = true
}

data "aws_caller_identity" "c1" { provider = aws.c1 }

data "aws_caller_identity" "c2" { provider = aws.c2 }

# Allow bastion to reach EKS API (cluster primary SG) over 443
resource "aws_security_group_rule" "c1_allow_bastion_to_eks_api" {
  count                    = var.create_bastion_instances ? 1 : 0
  provider                 = aws.c1
  type                     = "ingress"
  description              = "Allow bastion to reach EKS API"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = module.eks_c1.cluster_primary_security_group_id
  source_security_group_id = aws_security_group.c1_bastion[0].id
}

resource "aws_security_group_rule" "c2_allow_bastion_to_eks_api" {
  count                    = var.create_bastion_instances ? 1 : 0
  provider                 = aws.c2
  type                     = "ingress"
  description              = "Allow bastion to reach EKS API"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = module.eks_c2.cluster_primary_security_group_id
  source_security_group_id = aws_security_group.c2_bastion[0].id
}

# ----- Grant EKS cluster access to bastion roles (so kubectl auth works) -----
resource "aws_eks_access_entry" "c1_bastion" {
  count         = var.create_bastion_instances ? 1 : 0
  provider      = aws.c1
  cluster_name  = module.eks_c1.cluster_name
  principal_arn = aws_iam_role.c1_bastion[0].arn
}

resource "aws_eks_access_policy_association" "c1_bastion_admin" {
  count         = var.create_bastion_instances ? 1 : 0
  provider      = aws.c1
  cluster_name  = module.eks_c1.cluster_name
  principal_arn = aws_iam_role.c1_bastion[0].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
}

resource "aws_eks_access_entry" "c2_bastion" {
  count         = var.create_bastion_instances ? 1 : 0
  provider      = aws.c2
  cluster_name  = module.eks_c2.cluster_name
  principal_arn = aws_iam_role.c2_bastion[0].arn
}

resource "aws_eks_access_policy_association" "c2_bastion_admin" {
  count         = var.create_bastion_instances ? 1 : 0
  provider      = aws.c2
  cluster_name  = module.eks_c2.cluster_name
  principal_arn = aws_iam_role.c2_bastion[0].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
}

# ---- expanded IAM inline policies (single set) with CloudFormation + STS + EKS versions ----
resource "aws_iam_role_policy" "c1_bastion_deploy" {
  count    = var.create_bastion_instances ? 1 : 0
  provider = aws.c1
  name     = "${var.project_name}-c1-bastion-deploy"
  role     = aws_iam_role.c1_bastion[0].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { "Sid" : "EKSDescribe", "Effect" : "Allow", "Action" : ["eks:DescribeCluster", "eks:ListClusters", "eks:DescribeClusterVersions"], "Resource" : "*" },
      { "Sid" : "ReadDescribeInfra", "Effect" : "Allow", "Action" : ["ec2:Describe*", "elasticloadbalancing:Describe*", "elbv2:Describe*"], "Resource" : "*" },
      { "Sid" : "IAMListAndOIDCReadGlobal", "Effect" : "Allow", "Action" : ["iam:ListOpenIDConnectProviders", "iam:GetOpenIDConnectProvider", "iam:ListPolicies", "iam:GetPolicy", "iam:GetPolicyVersion", "iam:GetRole", "iam:ListAttachedRolePolicies"], "Resource" : "*" },
      { "Sid" : "IAMCreatePolicyGlobal", "Effect" : "Allow", "Action" : ["iam:CreatePolicy"], "Resource" : "*" },
      { "Sid" : "CFNForEksctl", "Effect" : "Allow", "Action" : ["cloudformation:CreateStack", "cloudformation:UpdateStack", "cloudformation:DescribeStacks", "cloudformation:DeleteStack", "cloudformation:ListStacks", "cloudformation:DescribeStackEvents", "cloudformation:DescribeStackResources", "cloudformation:GetTemplate", "cloudformation:CreateChangeSet", "cloudformation:ExecuteChangeSet", "cloudformation:DeleteChangeSet"], "Resource" : "*" },
      { "Sid" : "STSGetCaller", "Effect" : "Allow", "Action" : ["sts:GetCallerIdentity"], "Resource" : "*" },
      { "Sid" : "ScopedIAMForAlbControllerSetup", "Effect" : "Allow", "Action" : ["iam:CreateRole", "iam:AttachRolePolicy", "iam:PutRolePolicy", "iam:TagRole"], "Resource" : ["arn:aws:iam::${data.aws_caller_identity.c1.account_id}:role/${var.project_name}-*", "arn:aws:iam::${data.aws_caller_identity.c1.account_id}:policy/${var.project_name}-*"] },
      { "Sid" : "EksctlRoleOperations", "Effect" : "Allow", "Action" : ["iam:CreateRole", "iam:AttachRolePolicy", "iam:PutRolePolicy", "iam:TagRole"], "Resource" : ["arn:aws:iam::${data.aws_caller_identity.c1.account_id}:role/eksctl-*"] }
    ]
  })
}

resource "aws_iam_role_policy" "c2_bastion_deploy" {
  count    = var.create_bastion_instances ? 1 : 0
  provider = aws.c2
  name     = "${var.project_name}-c2-bastion-deploy"
  role     = aws_iam_role.c2_bastion[0].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { "Sid" : "EKSDescribe", "Effect" : "Allow", "Action" : ["eks:DescribeCluster", "eks:ListClusters", "eks:DescribeClusterVersions"], "Resource" : "*" },
      { "Sid" : "ReadDescribeInfra", "Effect" : "Allow", "Action" : ["ec2:Describe*", "elasticloadbalancing:Describe*", "elbv2:Describe*"], "Resource" : "*" },
      { "Sid" : "IAMListAndOIDCReadGlobal", "Effect" : "Allow", "Action" : ["iam:ListOpenIDConnectProviders", "iam:GetOpenIDConnectProvider", "iam:ListPolicies", "iam:GetPolicy", "iam:GetPolicyVersion", "iam:GetRole", "iam:ListAttachedRolePolicies"], "Resource" : "*" },
      { "Sid" : "IAMCreatePolicyGlobal", "Effect" : "Allow", "Action" : ["iam:CreatePolicy"], "Resource" : "*" },
      { "Sid" : "CFNForEksctl", "Effect" : "Allow", "Action" : ["cloudformation:CreateStack", "cloudformation:UpdateStack", "cloudformation:DescribeStacks", "cloudformation:DeleteStack", "cloudformation:ListStacks", "cloudformation:DescribeStackEvents", "cloudformation:DescribeStackResources", "cloudformation:GetTemplate", "cloudformation:CreateChangeSet", "cloudformation:ExecuteChangeSet", "cloudformation:DeleteChangeSet"], "Resource" : "*" },
      { "Sid" : "STSGetCaller", "Effect" : "Allow", "Action" : ["sts:GetCallerIdentity"], "Resource" : "*" },
      { "Sid" : "ScopedIAMForAlbControllerSetup", "Effect" : "Allow", "Action" : ["iam:CreateRole", "iam:AttachRolePolicy", "iam:PutRolePolicy", "iam:TagRole"], "Resource" : ["arn:aws:iam::${data.aws_caller_identity.c2.account_id}:role/${var.project_name}-*", "arn:aws:iam::${data.aws_caller_identity.c2.account_id}:policy/${var.project_name}-*"] },
      { "Sid" : "EksctlRoleOperations", "Effect" : "Allow", "Action" : ["iam:CreateRole", "iam:AttachRolePolicy", "iam:PutRolePolicy", "iam:TagRole"], "Resource" : ["arn:aws:iam::${data.aws_caller_identity.c2.account_id}:role/eksctl-*"] }
    ]
  })
}

# ---------- Outputs ----------
output "bastion_ssh_private_key_pem" {
  value     = can(tls_private_key.bastion[0].private_key_pem) ? tls_private_key.bastion[0].private_key_pem : null
  sensitive = true
}

output "bastion_ssh_public_key_openssh" {
  value = can(tls_private_key.bastion[0].public_key_openssh) ? tls_private_key.bastion[0].public_key_openssh : null
}

output "c1_bastion_key_name" {
  value = can(aws_key_pair.c1_bastion[0].key_name) ? aws_key_pair.c1_bastion[0].key_name : null
}

output "c2_bastion_key_name" {
  value = can(aws_key_pair.c2_bastion[0].key_name) ? aws_key_pair.c2_bastion[0].key_name : null
}

output "c1_bastion_instance_id" { value = aws_instance.c1_bastion[0].id }
output "c2_bastion_instance_id" { value = aws_instance.c2_bastion[0].id }
output "c1_bastion_public_ip" { value = aws_instance.c1_bastion[0].public_ip }
output "c2_bastion_public_ip" { value = aws_instance.c2_bastion[0].public_ip }
