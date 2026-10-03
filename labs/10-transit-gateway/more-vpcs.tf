# =============================================================================
# More than one network.
#
# The shop is no longer the company's only workload. Two more VPCs appear:
#
#   shared   tools every team uses -- here, one host serving on :8080
#   dev      where the next version of the shop is built
#
# They are separate VPCs rather than more subnets because they have different
# owners, different blast radius and, for dev, no business reaching production.
# A VPC is an isolation boundary: by default NOTHING crosses it.
#
# This file only builds them. How they are connected is the subject of
# peering.tf (lab 09) and transit-gateway.tf (lab 10).
# =============================================================================

variable "shared_vpc_cidr" {
  description = "IPv4 range of the shared-services VPC. Must not overlap any other VPC: overlapping networks cannot be routed to each other, by any mechanism."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.shared_vpc_cidr, 0)) && cidrhost(var.shared_vpc_cidr, 0) == split("/", var.shared_vpc_cidr)[0]
    error_message = "shared_vpc_cidr must be a valid IPv4 network address with all host bits zero."
  }

  validation {
    condition     = can(regex("^.*/16$", var.shared_vpc_cidr))
    error_message = "shared_vpc_cidr must be a /16, like every VPC in the address plan."
  }
}

variable "dev_vpc_cidr" {
  description = "IPv4 range of the dev VPC. Must not overlap any other VPC."
  type        = string
  default     = "10.30.0.0/16"

  validation {
    condition     = can(cidrhost(var.dev_vpc_cidr, 0)) && cidrhost(var.dev_vpc_cidr, 0) == split("/", var.dev_vpc_cidr)[0]
    error_message = "dev_vpc_cidr must be a valid IPv4 network address with all host bits zero."
  }

  validation {
    condition     = can(regex("^.*/16$", var.dev_vpc_cidr))
    error_message = "dev_vpc_cidr must be a /16, like every VPC in the address plan."
  }
}

variable "supernet_cidr" {
  description = "One range that contains every VPC in the project. Planning addresses so that such a range exists is what lets a single route, or a single firewall rule, cover networks that have not been built yet."
  type        = string
  default     = "10.0.0.0/8"

  validation {
    condition     = can(cidrhost(var.supernet_cidr, 0))
    error_message = "supernet_cidr must be a valid IPv4 CIDR."
  }
}

locals {
  other_vpcs = {
    shared = { cidr = var.shared_vpc_cidr }
    dev    = { cidr = var.dev_vpc_cidr }
  }

  tools_port = 8080

  # Every VPC in the project, in one place, for the connectivity files.
  vpc_cidrs = merge(
    { shop = var.vpc_cidr },
    { for name, vpc in local.other_vpcs : name => vpc.cidr },
  )

  vpc_ids = merge(
    { shop = module.vpc.vpc_id },
    { for name, vpc in module.other_vpc : name => vpc.vpc_id },
  )

  # Route tables per VPC. A connection between two VPCs does nothing until
  # EVERY route table that should use it has a route -- the shop has three.
  vpc_route_table_ids = merge(
    {
      shop = merge(
        { public = module.vpc.public_route_table_id },
        { for i, letter in local.az_letters : "private-${letter}" => module.vpc.private_route_table_ids[tostring(i)] },
      )
    },
    { for name, vpc in module.other_vpc : name => { public = vpc.public_route_table_id } },
  )
}

# Every range is a /16, so two of them overlap exactly when they start at the
# same address.
check "vpc_ranges_do_not_overlap" {
  assert {
    condition     = length(distinct([for cidr in values(local.vpc_cidrs) : cidrhost(cidr, 0)])) == length(local.vpc_cidrs)
    error_message = "Two VPCs have the same address range. Peering, Transit Gateway and VPN all refuse or misroute overlapping networks; give each VPC its own /16."
  }
}

module "other_vpc" {
  source   = "../../modules/vpc"
  for_each = local.other_vpcs

  name       = "${local.name_prefix}-${each.key}"
  cidr_block = each.value.cidr

  # One public subnet is enough: these VPCs exist to be connected to, and a
  # public address gives their test host a free path to Session Manager.
  public_subnets = {
    "public-a" = {
      cidr_block              = cidrsubnet(each.value.cidr, 8, 0)
      az_index                = 0
      map_public_ip_on_launch = true
    }
  }
  create_internet_gateway = true

  tags = merge(local.common_tags, { Vpc = each.key })
}

module "other_apps" {
  source   = "../../modules/demo-service"
  for_each = local.other_vpcs

  services = {
    "${each.key}-tools" = { port = local.tools_port }
  }
}

module "other_host" {
  source   = "../../modules/test-instance"
  for_each = local.other_vpcs

  name          = "${local.name_prefix}-${each.key}"
  vpc_id        = module.other_vpc[each.key].vpc_id
  subnet_id     = module.other_vpc[each.key].public_subnet_ids["public-a"]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  associate_public_ip_address = true

  user_data                   = module.other_apps[each.key].user_data
  user_data_replace_on_change = true

  # Open to the whole supernet on purpose. Security groups are then never the
  # reason a cross-VPC test fails, so every failure you see is ROUTING.
  ingress_rules = {
    tools = {
      description = "Tools service from any VPC in the project"
      ip_protocol = "tcp"
      from_port   = local.tools_port
      to_port     = local.tools_port
      cidr_ipv4   = var.supernet_cidr
    }
    icmp = {
      description = "ICMP echo request from any VPC in the project"
      ip_protocol = "icmp"
      from_port   = 8
      to_port     = -1
      cidr_ipv4   = var.supernet_cidr
    }
  }

  tags = merge(local.common_tags, { Vpc = each.key })
}

# The shop's web and app hosts answer ping from the other VPCs, for the same
# reason. Their service ports stay as restricted as before.
resource "aws_vpc_security_group_ingress_rule" "shop_icmp_from_supernet" {
  for_each = {
    web = module.web.security_group_id
    app = module.app.security_group_id
  }

  security_group_id = each.value
  description       = "ICMP echo request from any VPC in the project"
  ip_protocol       = "icmp"
  from_port         = 8
  to_port           = -1
  cidr_ipv4         = var.supernet_cidr
}

output "vpc_cidrs" {
  description = "Address range of every VPC in the project."
  value       = local.vpc_cidrs
}

output "other_host_private_ips" {
  description = "Private address of the test host in the shared and dev VPCs."
  value       = { for name, host in module.other_host : name => host.private_ip }
}

output "ssm_other_hosts" {
  description = "Open a shell on the shared or dev host."
  value       = { for name, host in module.other_host : name => host.ssm_start_session_command }
}
