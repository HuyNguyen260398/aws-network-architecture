# =============================================================================
# The network.
#
# Lab 01: one VPC, one public subnet, one internet gateway.
# Lab 02: three tiers -- public, app, data -- across two Availability Zones.
#         Only the public tier has a route to the internet gateway.
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
  # Two Availability Zones. A subnet lives in exactly one zone, so every tier
  # needs one subnet per zone to survive a zone failure.
  az_letters = ["a", "b"]

  # The address plan. /24 number N of the VPC range:
  #   0-9    public  (web tier, load balancers, NAT)
  #   10-19  app     (payment service)
  #   20-29  data    (database)
  # Leaving gaps means a tier can grow without renumbering its neighbours.
  # The keys are resource addresses: public-a keeps the number it had in
  # lab 01, so adding the rest does not replace it.
  public_subnets = {
    for i, letter in local.az_letters : "public-${letter}" => {
      cidr_block = cidrsubnet(var.vpc_cidr, 8, i)
      az_index   = i
      # Instances launched here get a public IPv4 address automatically.
      map_public_ip_on_launch = true
    }
  }

  app_subnets = {
    for i, letter in local.az_letters : "app-${letter}" => {
      cidr_block = cidrsubnet(var.vpc_cidr, 8, 10 + i)
      az_index   = i
    }
  }

  data_subnets = {
    for i, letter in local.az_letters : "data-${letter}" => {
      cidr_block = cidrsubnet(var.vpc_cidr, 8, 20 + i)
      az_index   = i
    }
  }

  # "Private" means one thing only: the subnet's route table has no route to
  # the internet gateway. The app and data tiers are both private.
  private_subnets = merge(local.app_subnets, local.data_subnets)
}

module "vpc" {
  source = "../../modules/vpc"

  name       = local.name_prefix
  cidr_block = var.vpc_cidr

  public_subnets          = local.public_subnets
  private_subnets         = local.private_subnets
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

output "private_subnets" {
  description = "App and data subnets: ID, CIDR and Availability Zone of each."
  value       = module.vpc.private_subnets
}

output "private_route_table_ids" {
  description = "Route tables of the private subnets, one per Availability Zone. They hold only the local route, so nothing in them can reach the internet."
  value       = module.vpc.private_route_table_ids
}

output "public_route_table_id" {
  description = "The route table whose 0.0.0.0/0 route to the internet gateway is what makes a subnet public."
  value       = module.vpc.public_route_table_id
}

output "verify_network" {
  description = "Read-only AWS CLI commands for checking the network."
  value = {
    subnets = "aws ec2 describe-subnets --filters Name=vpc-id,Values=${module.vpc.vpc_id} --region ${var.aws_region} --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,CIDR:CidrBlock,AZ:AvailabilityZone,AutoPublicIP:MapPublicIpOnLaunch}' --output table"

    private_route_tables = "aws ec2 describe-route-tables --filters Name=vpc-id,Values=${module.vpc.vpc_id} Name=tag:Name,Values='*rt-private*' --region ${var.aws_region} --query 'RouteTables[].{Name:Tags[?Key==`Name`]|[0].Value,Routes:Routes[].{Dest:DestinationCidrBlock,GW:GatewayId,NAT:NatGatewayId}}' --output json"

    public_route_table = "aws ec2 describe-route-tables --route-table-ids ${module.vpc.public_route_table_id} --region ${var.aws_region} --query 'RouteTables[0].Routes' --output table"
  }
}
