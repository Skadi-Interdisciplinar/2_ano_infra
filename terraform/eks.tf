data "aws_caller_identity" "current" {}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = true
  # O Learner Lab nega iam:GetRole na role voclabs. Com esta opcao ligada,
  # o modulo tenta essa leitura e o plan morre antes de criar o cluster.
  enable_cluster_creator_admin_permissions = false

  access_entries = {
    voclabs = {
      principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/voclabs"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  eks_managed_node_groups = {
    skadi = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]
      min_size       = 1
      max_size       = 2
      desired_size   = 1
      capacity_type  = "ON_DEMAND"
      subnet_ids     = module.vpc.public_subnets
    }
  }

  tags = {
    Project = "skadi"
  }
}
