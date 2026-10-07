output "aws_region" {
  value = var.aws_region
}

output "cluster_name" {
  value = module.eks.cluster_name
}
