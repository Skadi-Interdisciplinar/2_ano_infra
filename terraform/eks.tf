data "aws_caller_identity" "current" {}

locals {
  # O Learner Lab nao permite iam:CreateRole. A unica role utilizavel ja existe na conta.
  lab_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/LabRole"
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = local.lab_role_arn

  vpc_config {
    subnet_ids              = module.vpc.public_subnets
    endpoint_public_access  = true
    endpoint_private_access = false
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = false
  }

  tags = {
    Project = "skadi"
  }
}

resource "aws_eks_access_entry" "voclabs" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/voclabs"
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "voclabs" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.voclabs.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

resource "aws_eks_node_group" "skadi" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "skadi"
  node_role_arn   = local.lab_role_arn
  subnet_ids      = module.vpc.public_subnets
  instance_types  = [var.node_instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"

  scaling_config {
    min_size     = 1
    max_size     = 2
    desired_size = 1
  }

  tags = {
    Project = "skadi"
  }
}
