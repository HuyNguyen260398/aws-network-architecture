# =============================================================================
# Lab 05 -- Transit Gateway
#
#          prod VPC          dev VPC          shared-services VPC
#             |                 |                      |
#             +--------- Transit Gateway --------------+
#                       /                    \
#           TGW RT "spoke"                TGW RT "shared"
#     (prod, dev associated)          (shared associated)
#     learns: shared only             learns: prod and dev
#
# prod -> shared   works
# dev  -> shared   works
# prod -> dev      DOES NOT WORK, by design
#
# The last line is the point. Every VPC is attached to the same gateway, and
# whether two of them can communicate is decided entirely by which Transit
# Gateway route table their attachment is associated with. This is network
# segmentation as a routing property, configured in one place rather than in
# every VPC's route table.
#
# ###########################################################################
# COST WARNING -- THE MOST EXPENSIVE LAB IN THIS REPOSITORY
#
#   Transit Gateway itself       free
#   Each VPC attachment          ~USD 0.05/hour   (~USD 36/month EACH)
#   Data processed               ~USD 0.02/GB
#
#   Three attachments = ~USD 0.15/hour = ~USD 3.60/day = ~USD 110/month.
#
# Nothing above is created unless BOTH enable_transit_gateway AND
# acknowledge_costs are true. With them false this lab builds three free,
# unconnected VPCs so you can read the topology at no cost.
# ###########################################################################
# =============================================================================

module "vpc" {
  source   = "../../modules/vpc"
  for_each = local.spokes

  name       = "${local.name_prefix}-${each.key}"
  cidr_block = each.value.cidr

  public_subnets = {
    # Workload subnet: holds the test instance.
    "public-a" = {
      cidr_block              = cidrsubnet(each.value.cidr, var.subnet_newbits, 0)
      az_index                = 0
      map_public_ip_on_launch = true
    }
    # Dedicated attachment subnet: a /28 holding nothing but the Transit
    # Gateway ENI. Keeping it separate means the workload subnet's network ACL
    # never applies to transiting traffic.
    "tgw-a" = {
      cidr_block              = cidrsubnet(each.value.cidr, local.tgw_subnet_newbits, local.tgw_subnet_netnum)
      az_index                = 0
      map_public_ip_on_launch = false
    }
  }

  create_internet_gateway = true
  nat_gateway_mode        = "none"

  tags = merge(local.common_tags, { Segment = each.value.segment, Spoke = each.key })
}

# =============================================================================
# Transit Gateway
# =============================================================================
resource "aws_ec2_transit_gateway" "this" {
  count = local.create_tgw ? 1 : 0

  description = "${local.name_prefix} hub"

  # Both defaults are DISABLED on purpose. AWS's default behaviour is to drop
  # every attachment into one shared route table with full propagation, which
  # produces a flat any-to-any network. Turning both off forces every
  # association and propagation to be written down explicitly -- which is both
  # the secure default and the only way to see what is actually happening.
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"

  # Lets the gateway resolve VPC private DNS names across attachments.
  dns_support = "enable"

  # Equal-cost multi-path across multiple VPN tunnels to the same gateway.
  # Harmless here; relevant in lab 07.
  vpn_ecmp_support = "enable"

  # Private ASN for BGP sessions with on-premises routers (lab 07).
  amazon_side_asn = 64512

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-tgw" })
}

# Each attachment is an ENI in the dedicated /28 subnet, and each is billed by
# the hour whether or not any traffic flows through it.
resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  for_each = local.create_tgw ? local.spokes : {}

  transit_gateway_id = aws_ec2_transit_gateway.this[0].id
  vpc_id             = module.vpc[each.key].vpc_id
  subnet_ids         = [module.vpc[each.key].public_subnet_ids["tgw-a"]]

  # Explicit rather than inherited, matching the gateway's disabled defaults.
  # The association and propagation resources below do the real work.
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  dns_support = "enable"

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-attach-${each.key}"
    Segment = each.value.segment
  })
}

# =============================================================================
# Transit Gateway route tables -- where segmentation lives
# =============================================================================
resource "aws_ec2_transit_gateway_route_table" "spoke" {
  count = local.create_tgw ? 1 : 0

  transit_gateway_id = aws_ec2_transit_gateway.this[0].id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-rt-spoke" })
}

resource "aws_ec2_transit_gateway_route_table" "shared" {
  count = local.create_tgw ? 1 : 0

  transit_gateway_id = aws_ec2_transit_gateway.this[0].id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-rt-shared" })
}

# ASSOCIATION: which route table this attachment consults when SENDING.
# Exactly one per attachment.
resource "aws_ec2_transit_gateway_route_table_association" "spoke" {
  for_each = local.create_tgw ? local.spoke_attachments : {}

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke[0].id
}

resource "aws_ec2_transit_gateway_route_table_association" "shared" {
  for_each = local.create_tgw ? local.shared_attachments : {}

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.shared[0].id
}

# PROPAGATION: which route tables LEARN about this attachment's VPC CIDR.
# Any number per attachment, and completely independent of association.
#
# The spoke table learns ONLY the shared VPC. That is the whole segmentation
# control: prod and dev consult this table, and it contains no route to each
# other, so their traffic is dropped at the gateway.
resource "aws_ec2_transit_gateway_route_table_propagation" "into_spoke_rt" {
  for_each = local.create_tgw ? local.spoke_rt_propagations : {}

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke[0].id
}

# The shared table learns prod and dev, so shared services can reach and reply
# to both. Note this is asymmetric with the spoke table above -- and asymmetry
# is exactly what you want here.
resource "aws_ec2_transit_gateway_route_table_propagation" "into_shared_rt" {
  for_each = local.create_tgw ? local.spoke_attachments : {}

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.shared[0].id
}

# A blackhole route silently discards traffic for a prefix at the gateway. This
# is how a compromised or decommissioned range is quarantined instantly, in one
# place, without touching any VPC route table.
#
# It is also a trap during troubleshooting: a blackhole route is not an error
# and appears as a perfectly healthy entry in the route table.
resource "aws_ec2_transit_gateway_route" "blackhole" {
  count = local.create_tgw ? 1 : 0

  destination_cidr_block         = var.blackhole_cidr
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke[0].id
  blackhole                      = true
}

# =============================================================================
# VPC route tables -- one summary route each
#
# Every VPC sends the whole supernet to the Transit Gateway with a single
# route. Adding a fourth VPC inside that supernet needs no change here at all;
# whether it can be reached is decided by the Transit Gateway route tables.
# =============================================================================
resource "aws_route" "to_tgw" {
  for_each = local.create_tgw ? local.spokes : {}

  route_table_id         = module.vpc[each.key].public_route_table_id
  destination_cidr_block = var.supernet_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this[0].id

  # The route is rejected until the attachment exists, and Terraform cannot
  # infer the ordering from the arguments alone.
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# =============================================================================
# Test instances
# =============================================================================
module "instance" {
  source   = "../../modules/test-instance"
  for_each = var.enable_test_instances ? local.spokes : {}

  name          = "${local.name_prefix}-${each.key}"
  vpc_id        = module.vpc[each.key].vpc_id
  subnet_id     = module.vpc[each.key].public_subnet_ids["public-a"]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  associate_public_ip_address = true

  # ICMP allowed from the entire supernet, deliberately. Security groups are
  # then never the reason a ping fails, so every failure you see is the Transit
  # Gateway route tables doing their job.
  ingress_rules = {
    icmp_from_supernet = {
      description = "ICMP echo request from anywhere in the lab supernet"
      ip_protocol = "icmp"
      from_port   = 8
      to_port     = -1
      cidr_ipv4   = var.supernet_cidr
    }
  }

  tags = merge(local.common_tags, { Segment = each.value.segment, Spoke = each.key })
}

check "transit_gateway_is_disabled" {
  assert {
    condition     = local.create_tgw
    error_message = "The Transit Gateway is DISABLED, so the three VPCs are not connected to anything. This is the default because three attachments cost about USD 0.15/hour (USD 110/month). Set acknowledge_costs = true and enable_transit_gateway = true when you are ready to run the lab, and destroy it the same day."
  }
}
