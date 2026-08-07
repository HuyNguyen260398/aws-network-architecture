# =============================================================================
# Reusable VPC
#
# One VPC, its subnets, its route tables, and the gateways that give those route
# tables somewhere to point. The design decision this module exists to make
# visible is that "public" and "private" are properties of ROUTING, not of a
# subnet's name or its CIDR: a public subnet is one whose route table has a
# 0.0.0.0/0 entry pointing at an internet gateway. Nothing else distinguishes them.
# =============================================================================

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block       = var.cidr_block
  instance_tenancy = var.instance_tenancy

  # Both are required for interface VPC endpoint private DNS and for Route 53
  # private hosted zones to resolve inside the VPC.
  enable_dns_support   = var.enable_dns_support
  enable_dns_hostnames = var.enable_dns_hostnames

  # Amazon hands out a /56. You cannot choose the range, which is precisely why
  # IPv6 sidesteps the overlapping-CIDR problems that plague IPv4 designs.
  assign_generated_ipv6_cidr_block = var.enable_ipv6

  tags = merge(local.tags, { Name = var.name })

  lifecycle {
    precondition {
      condition     = length(local.subnets_outside_vpc) == 0
      error_message = "These subnets fall outside the VPC CIDR ${var.cidr_block}: ${join(", ", local.subnets_outside_vpc)}. Every subnet must be a sub-range of the VPC block."
    }

    precondition {
      condition     = length(local.overlapping_subnets) == 0
      error_message = "Overlapping subnet CIDRs: ${join("; ", local.overlapping_subnets)}. Subnets within a VPC must not overlap."
    }

    precondition {
      condition     = length(local.subnets_with_bad_az) == 0
      error_message = "These subnets specify an az_index beyond the ${local.az_count} Availability Zones available here: ${join(", ", local.subnets_with_bad_az)}. Valid indexes are 0 to ${local.az_count - 1}."
    }

    precondition {
      condition     = var.nat_gateway_mode == "none" || length(var.public_subnets) > 0
      error_message = "nat_gateway_mode is '${var.nat_gateway_mode}' but no public subnets are defined. A NAT gateway must sit in a public subnet, because it needs its own route to the internet gateway."
    }

    precondition {
      condition     = var.nat_gateway_mode == "none" || var.create_internet_gateway
      error_message = "nat_gateway_mode is '${var.nat_gateway_mode}' but create_internet_gateway is false. A NAT gateway with no internet gateway to forward to is a black hole."
    }
  }
}

# Strips every rule from the default security group. AWS creates it allowing all
# traffic between members and all outbound traffic; anything launched without an
# explicit security group silently lands in it.
resource "aws_default_security_group" "this" {
  count = var.manage_default_security_group ? 1 : 0

  vpc_id = aws_vpc.this.id

  # No ingress or egress blocks: Terraform removes all rules, leaving a security
  # group that permits nothing in either direction.

  tags = merge(local.tags, { Name = "${var.name}-default-do-not-use" })
}

# The main route table. Subnets with no explicit association fall back here, so
# keeping it routeless means a missed association fails closed.
resource "aws_default_route_table" "this" {
  count = var.manage_default_route_table ? 1 : 0

  default_route_table_id = aws_vpc.this.default_route_table_id

  # No route blocks: only the implicit local route for the VPC CIDR survives.

  tags = merge(local.tags, { Name = "${var.name}-main-unused" })
}

# -----------------------------------------------------------------------------
# Gateways
# -----------------------------------------------------------------------------

# Internet gateways are free to create and free to keep. You pay only for data
# transfer out to the internet.
resource "aws_internet_gateway" "this" {
  count = local.create_igw ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-igw" })
}

# The IPv6 counterpart of a NAT gateway: outbound connections are allowed,
# unsolicited inbound ones are dropped. Unlike NAT it is completely free, which
# is one of the better arguments for dual-stack lab networks.
resource "aws_egress_only_internet_gateway" "this" {
  count = local.create_eoigw ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-eigw" })
}

# -----------------------------------------------------------------------------
# Subnets
# -----------------------------------------------------------------------------
resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr_block
  availability_zone = each.value.availability_zone

  # Auto-assigning a public IPv4 address is what makes an instance in this
  # subnet reachable without an Elastic IP. Public IPv4 addresses are billed
  # hourly, so this defaults to false.
  map_public_ip_on_launch = each.value.map_public_ip_on_launch

  ipv6_cidr_block                 = each.value.ipv6_cidr_block
  assign_ipv6_address_on_creation = var.enable_ipv6

  tags = merge(local.tags, {
    Name = "${var.name}-${each.key}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr_block
  availability_zone = each.value.availability_zone

  ipv6_cidr_block                 = each.value.ipv6_cidr_block
  assign_ipv6_address_on_creation = var.enable_ipv6

  tags = merge(local.tags, {
    Name = "${var.name}-${each.key}"
    Tier = "private"
  })
}

# -----------------------------------------------------------------------------
# NAT gateways
#
# COST WARNING: roughly USD 0.059/hour plus USD 0.059/GB processed in
# ap-southeast-1. Created only when nat_gateway_mode is 'single' or 'per_az'.
# -----------------------------------------------------------------------------
resource "aws_eip" "nat" {
  for_each = local.nat_gateways

  domain = "vpc"

  tags = merge(local.tags, { Name = "${var.name}-nat-eip-az${each.key}" })

  # The EIP is useless until the IGW exists, and destroying them in the wrong
  # order leaves a dangling address that is billed while unattached.
  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  for_each = local.nat_gateways

  allocation_id     = aws_eip.nat[each.key].id
  subnet_id         = aws_subnet.public[each.value].id
  connectivity_type = "public"

  tags = merge(local.tags, { Name = "${var.name}-nat-az${each.key}" })

  depends_on = [aws_internet_gateway.this]
}

# -----------------------------------------------------------------------------
# Public route table
#
# ONE table shared by every public subnet. Public subnets all want the same
# answer -- send everything you do not recognise to the internet gateway -- so
# there is nothing to gain from per-AZ tables here.
# -----------------------------------------------------------------------------
resource "aws_route_table" "public" {
  count = length(var.public_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-rt-public" })
}

# THIS ROUTE is what makes a "public" subnet public. Remove it and the subnets
# below become private, whatever their names say.
resource "aws_route" "public_default_ipv4" {
  count = length(var.public_subnets) > 0 && local.create_igw ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route" "public_default_ipv6" {
  count = length(var.public_subnets) > 0 && local.create_igw && var.enable_ipv6 ? 1 : 0

  route_table_id              = aws_route_table.public[0].id
  destination_ipv6_cidr_block = "::/0"
  gateway_id                  = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  for_each = local.public_subnets

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public[0].id
}

# -----------------------------------------------------------------------------
# Private route tables, one per Availability Zone
# -----------------------------------------------------------------------------
resource "aws_route_table" "private" {
  for_each = toset(local.private_azs_sorted)

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${var.name}-rt-private-az${each.key}"
  })
}

# Only exists when a NAT gateway does. With nat_gateway_mode = "none" the
# private route tables contain nothing but the VPC-local route, which is what
# makes those subnets genuinely isolated.
resource "aws_route" "private_default_ipv4" {
  for_each = {
    for az, nat_az in local.private_az_nat : az => nat_az
    if nat_az != null
  }

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[each.value].id
}

# IPv6 outbound goes to the egress-only gateway. Note there is no IPv6 NAT on
# AWS at all -- every IPv6 address is globally routable, and the egress-only
# gateway provides the "outbound but not inbound" behaviour instead.
resource "aws_route" "private_default_ipv6" {
  for_each = local.create_eoigw ? toset(local.private_azs_sorted) : toset([])

  route_table_id              = aws_route_table.private[each.key].id
  destination_ipv6_cidr_block = "::/0"
  egress_only_gateway_id      = aws_egress_only_internet_gateway.this[0].id
}

resource "aws_route_table_association" "private" {
  for_each = local.private_subnets

  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[tostring(each.value.az_index)].id
}
