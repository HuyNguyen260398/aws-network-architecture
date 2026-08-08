# =============================================================================
# Lab 04 -- Multi-VPC connectivity with VPC peering
#
# Three VPCs in a hub-and-spoke shape:
#
#     B <---peered---> A <---peered---> C
#
# B and A can talk. A and C can talk. **B and C cannot**, and no amount of route
# table editing will change that. VPC peering is not transitive: a packet cannot
# enter a VPC over one peering connection and leave over another.
#
# That single property is why VPC peering does not scale, and why Transit
# Gateway (lab 05) exists.
#
# COST: peering connections are FREE to create and free to keep. You pay only
# for data crossing them (about USD 0.01/GB each way within a Region, and
# nothing at all between instances in the same Availability Zone). The only
# charges in this lab are the optional test instances.
# =============================================================================

module "vpc" {
  source   = "../../modules/vpc"
  for_each = local.active_vpcs

  name       = "${local.name_prefix}-${each.key}"
  cidr_block = each.value.cidr

  # One public subnet per VPC. Public purely so the test instance can reach
  # Systems Manager -- the peering tests all use private addresses.
  public_subnets = {
    "public-a" = {
      cidr_block              = cidrsubnet(each.value.cidr, var.subnet_newbits, 0)
      az_index                = 0
      map_public_ip_on_launch = true
    }
  }

  create_internet_gateway = true
  nat_gateway_mode        = "none"

  tags = merge(local.common_tags, { Vpc = upper(each.key) })
}

# =============================================================================
# Peering connections
#
# Same account and same Region, so auto_accept works. Across accounts you would
# create aws_vpc_peering_connection in the requester account and
# aws_vpc_peering_connection_accepter in the accepter account, using a second
# provider alias -- see the README.
# =============================================================================
resource "aws_vpc_peering_connection" "this" {
  for_each = local.peerings

  vpc_id      = module.vpc[each.value.from].vpc_id
  peer_vpc_id = module.vpc[each.value.to].vpc_id

  # Only valid when both VPCs are in the same account and Region.
  auto_accept = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-pcx-${each.key}"
  })
}

# DNS resolution across the peering connection. Without this, a private hosted
# zone record or an instance's private DNS name in the peer VPC resolves to its
# PUBLIC address, and the traffic then leaves via the internet gateway instead
# of the peering connection -- working, but not the way you intended, and billed
# as internet egress.
resource "aws_vpc_peering_connection_options" "this" {
  for_each = local.peerings

  vpc_peering_connection_id = aws_vpc_peering_connection.this[each.key].id

  requester {
    allow_remote_vpc_dns_resolution = true
  }

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
}

# =============================================================================
# Routes
#
# A peering connection is only a permission to route. Until both sides have a
# route entry, no packet moves. Missing ONE of the two is the most common
# peering fault: the request arrives, the reply has nowhere to go, and the
# symptom is a timeout that looks like a security group problem.
# =============================================================================
resource "aws_route" "peering" {
  for_each = local.peering_routes

  route_table_id            = module.vpc[each.value.source_vpc].public_route_table_id
  destination_cidr_block    = each.value.dest_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this[each.value.peering_key].id
}

# =============================================================================
# Test instances -- one per VPC
# =============================================================================
module "instance" {
  source   = "../../modules/test-instance"
  for_each = var.enable_test_instances ? local.active_vpcs : {}

  name          = "${local.name_prefix}-${each.key}"
  vpc_id        = module.vpc[each.key].vpc_id
  subnet_id     = module.vpc[each.key].public_subnet_ids["public-a"]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  associate_public_ip_address = true

  # Allow ICMP from every VPC in the lab, including the ones this VPC is not
  # peered with. That matters: it removes the security group as a possible
  # explanation, so when B cannot ping C you know it is routing.
  ingress_rules = merge([
    for k, v in local.active_vpcs : {
      "icmp_from_vpc_${k}" = {
        description = "ICMP echo request from VPC ${upper(k)} (${v.cidr})"
        ip_protocol = "icmp"
        from_port   = 8
        to_port     = -1
        cidr_ipv4   = v.cidr
      }
    }
  ]...)

  tags = merge(local.common_tags, { Vpc = upper(each.key) })
}

# The non-transitivity of peering is the point of this lab, so surface it as a
# warning rather than leaving it to be discovered by a failed ping.
check "peering_is_not_transitive" {
  assert {
    condition     = !var.enable_vpc_c || var.enable_b_to_c_peering
    error_message = "VPC B and VPC C are both peered with A, and neither can reach the other. This is expected: VPC peering is not transitive. Set enable_b_to_c_peering = true to add the third connection and see the full-mesh fix -- then count how many connections ten VPCs would need."
  }
}
