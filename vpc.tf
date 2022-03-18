data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.12"

  name = var.unique_name

  cidr = "10.1.0.0/16"

  azs              = data.aws_availability_zones.available.names
  private_subnets  = ["10.1.1.0/24", "10.1.2.0/24"]
  public_subnets   = ["10.1.11.0/24", "10.1.12.0/24"]
  database_subnets = ["10.1.201.0/24", "10.1.202.0/24"]

  enable_nat_gateway = false

  tags = local.tags
}
