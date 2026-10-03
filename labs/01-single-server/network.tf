# =============================================================================
# The network.
#
# Lab 01: one VPC, one public subnet, one internet gateway. The smallest
# network that can put a server on the internet.
# =============================================================================

variable "vpc_cidr" {
  description = "IPv4 range for the shop VPC. A /16 leaves room for every tier, Availability Zone and later lab; subnets are /24s carved from it."
  type        = string
  default     = "10.10.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && cidrhost(var.vpc_cidr, 0) == split("/", var.vpc_cidr)[0]
    error_message = "vpc_cidr must be a valid IPv4 network address with all host bits zero."
  }

  validation {
    condition     = can(regex("^.*/16$", var.vpc_cidr))
    error_message = "vpc_cidr must be a /16. The address plan in docs/address-plan.md, and every later lab, assumes /24 subnets numbered 0-255 inside it."
  }
}

locals {
  # /24 number 0 of the VPC range. The key is a resource address: later labs
  # add subnets beside this one without renaming it, so it is never replaced.
  public_subnets = {
    "public-a" = {
      cidr_block = cidrsubnet(var.vpc_cidr, 8, 0)
      az_index   = 0
      # Instances launched here get a public IPv4 address automatically. That
      # address, plus the 0.0.0.0/0 route to the internet gateway, is what
      # makes the server reachable from the internet.
      map_public_ip_on_launch = true
    }
  }
}

module "vpc" {
  source = "../../modules/vpc"

  name       = local.name_prefix
  cidr_block = var.vpc_cidr

  public_subnets          = local.public_subnets
  create_internet_gateway = true

  tags = local.common_tags
}

output "vpc_id" {
  description = "ID of the shop VPC."
  value       = module.vpc.vpc_id
}

output "public_subnets" {
  description = "Public subnets: ID, CIDR and Availability Zone of each."
  value       = module.vpc.public_subnets
}

output "public_route_table_id" {
  description = "The route table whose 0.0.0.0/0 route to the internet gateway is what makes a subnet public."
  value       = module.vpc.public_route_table_id
}

output "verify_network" {
  description = "Read-only AWS CLI commands for checking the network."
  value = {
    subnets = "aws ec2 describe-subnets --filters Name=vpc-id,Values=${module.vpc.vpc_id} --region ${var.aws_region} --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,CIDR:CidrBlock,AZ:AvailabilityZone,AutoPublicIP:MapPublicIpOnLaunch}' --output table"

    public_route_table = "aws ec2 describe-route-tables --route-table-ids ${module.vpc.public_route_table_id} --region ${var.aws_region} --query 'RouteTables[0].Routes' --output table"
  }
}
