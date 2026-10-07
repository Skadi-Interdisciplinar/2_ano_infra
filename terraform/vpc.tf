data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.21"

  name = var.cluster_name
  cidr = "10.0.0.0/16"

  azs            = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets = ["10.0.1.0/24", "10.0.2.0/24"]

  enable_nat_gateway      = false
  enable_dns_hostnames    = true
  enable_dns_support      = true
  map_public_ip_on_launch = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = {
    Project = "skadi"
  }
}
