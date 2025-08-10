data "aws_eks_cluster" "c1" {
  provider = aws.c1
  name     = var.c1_cluster_name
}

data "aws_eks_cluster_auth" "c1" {
  provider = aws.c1
  name     = var.c1_cluster_name
}

provider "kubernetes" {
  alias                  = "c1"
  host                   = data.aws_eks_cluster.c1.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.c1.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.c1.token
}

data "aws_eks_cluster" "c2" {
  provider = aws.c2
  name     = var.c2_cluster_name
}

data "aws_eks_cluster_auth" "c2" {
  provider = aws.c2
  name     = var.c2_cluster_name
}

provider "kubernetes" {
  alias                  = "c2"
  host                   = data.aws_eks_cluster.c2.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.c2.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.c2.token
}

provider "helm" {
  alias = "c2"
  kubernetes {
    host                   = data.aws_eks_cluster.c2.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.c2.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.c2.token
  }
}
