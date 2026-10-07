variable "aws_region" {
  description = "Regiao do Learner Lab. A AWS Academy costuma liberar us-east-1."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Nome do cluster EKS e prefixo dos recursos."
  type        = string
  default     = "skadi"
}

variable "cluster_version" {
  description = "Versao do Kubernetes no EKS, dentro do suporte padrao."
  type        = string
  default     = "1.34"
}

variable "node_instance_type" {
  description = "Tipo da instancia do unico node group."
  type        = string
  default     = "t3.medium"
}
