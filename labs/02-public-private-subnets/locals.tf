locals {
  lab_name    = "02-public-private-subnets"
  name_prefix = "${var.project_name}-lab02"

  common_tags = merge(
    {
      Project     = var.project_name
      Lab         = local.lab_name
      Environment = "learning"
      ManagedBy   = "terraform"
      Lifecycle   = "ephemeral"
    },
    var.additional_tags,
  )

  az_letters = ["a", "b", "c", "d"]

  # Public subnets from the bottom of the range, private from the top half.
  private_netnum_offset = floor(pow(2, var.subnet_newbits) / 2)

  public_subnets = {
    for i in range(var.az_count) : "public-${local.az_letters[i]}" => {
      cidr_block = cidrsubnet(var.vpc_cidr, var.subnet_newbits, i)
      az_index   = i
      # ON in this lab, unlike lab 01. An instance launched here gets a public
      # IPv4 address automatically, which is what lets it reach the Systems
      # Manager endpoints through the internet gateway with no NAT gateway at
      # all. The address is billed at roughly USD 0.005/hour.
      map_public_ip_on_launch = true
    }
  }

  private_subnets = {
    for i in range(var.az_count) : "private-${local.az_letters[i]}" => {
      cidr_block = cidrsubnet(var.vpc_cidr, var.subnet_newbits, local.private_netnum_offset + i)
      az_index   = i
    }
  }

  # Two gates: the feature flag and the cost acknowledgement. The validation on
  # enable_nat_gateway already refuses the combination, so this is belt and
  # braces for anyone who edits the variable defaults.
  nat_gateway_mode = var.enable_nat_gateway && var.acknowledge_costs ? var.nat_gateway_mode : "none"

  # An egress-only internet gateway is meaningless without IPv6.
  enable_eoigw = var.enable_ipv6 && var.enable_egress_only_internet_gateway

  first_public_subnet_key  = "public-${local.az_letters[0]}"
  first_private_subnet_key = "private-${local.az_letters[0]}"

  # Rough standing cost, printed as an output so it is visible without reading
  # the README. NAT figures are ap-southeast-1 list prices.
  estimated_hourly_usd = (
    (local.nat_gateway_mode == "none" ? 0 : (local.nat_gateway_mode == "per_az" ? var.az_count : 1)) * 0.059
    + (var.enable_test_instances ? (2 * 0.0053 + 0.005) : 0)
  )
}
