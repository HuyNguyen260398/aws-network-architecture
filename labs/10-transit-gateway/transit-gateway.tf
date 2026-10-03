# =============================================================================
# Transit Gateway.
#
# Peering joined pairs. Three VPCs needed two connections and a dozen routes;
# ten would need 45 connections, and every new VPC would mean touching every
# existing one. This lab REPLACES the peering connections with a hub.
#
# A Transit Gateway is a regional router. Each VPC attaches to it once, and
# each VPC route table needs one route: "everything in the supernet -> the
# gateway". Whether two VPCs can actually talk is then decided in ONE place,
# the gateway's own route tables:
#
#   spoke table    used by shop and dev.  Knows only the shared VPC.
#   shared table   used by shared.        Knows shop and dev.
#
# So shop and dev both reach shared, and cannot reach each other -- the same
# outcome as lab 09, now as an explicit policy instead of a side effect.
# =============================================================================

variable "enable_transit_gateway" {
  description = <<-EOT
    Create the Transit Gateway and attach all three VPCs.

    COST: the gateway itself is free. Each VPC attachment is about USD 0.05
    per hour, so three are USD 0.15/hour -- USD 3.60/day, USD 110/month --
    plus USD 0.02 per GB processed.

    While this is false the three VPCs are not connected to anything: lab 09's
    peering connections are gone and nothing has replaced them.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_transit_gateway || var.acknowledge_costs
    error_message = "enable_transit_gateway requires acknowledge_costs = true. Three attachments cost about USD 110/month."
  }
}

variable "allow_dev_to_shop" {
  description = "Propagate the shop's routes into the spoke route table, so dev can reach production. A segmentation hole, opened deliberately to show that one propagation is all that separates the two."
  type        = bool
  default     = false
}

variable "blackhole_cidr" {
  description = "A prefix the Transit Gateway silently drops for spoke VPCs. 192.0.2.0/24 is reserved for documentation, so the default harms nothing."
  type        = string
  default     = "192.0.2.0/24"

  validation {
    condition     = can(cidrhost(var.blackhole_cidr, 0))
    error_message = "blackhole_cidr must be a valid IPv4 CIDR."
  }
}

locals {
  create_tgw = var.enable_transit_gateway && var.acknowledge_costs

  # Which Transit Gateway route table each VPC consults.
  tgw_segments = {
    shop   = "spoke"
    dev    = "spoke"
    shared = "shared"
  }

  tgw_spoke_attachments  = { for name, segment in local.tgw_segments : name => segment if segment == "spoke" }
  tgw_shared_attachments = { for name, segment in local.tgw_segments : name => segment if segment == "shared" }

  # What the spoke table learns: the shared VPC, and the shop only if the
  # hole is opened.
  tgw_spoke_table_learns = merge(
    local.tgw_shared_attachments,
    var.allow_dev_to_shop ? { shop = "spoke" } : {},
  )

  tgw_vpc_routes = merge([
    for vpc, route_tables in local.vpc_route_table_ids : {
      for rt_name, rt_id in route_tables : "${vpc}-${rt_name}" => { vpc = vpc, route_table_id = rt_id }
    }
  ]...)
}

# -----------------------------------------------------------------------------
# Attachment subnets
#
# An attachment places a network interface in a subnet. Giving it a small
# subnet of its own -- the last /28 of each VPC -- keeps the gateway's
# interfaces apart from workloads, so a network ACL can treat them separately.
# -----------------------------------------------------------------------------
resource "aws_subnet" "tgw" {
  for_each = local.create_tgw ? local.vpc_cidrs : {}

  vpc_id            = local.vpc_ids[each.key]
  cidr_block        = cidrsubnet(each.value, 12, 4095)
  availability_zone = module.vpc.availability_zones[0]

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-${each.key}-tgw-a" })
}

# -----------------------------------------------------------------------------
# The gateway and its attachments
# -----------------------------------------------------------------------------
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
  # Harmless here; relevant in lab 12.
  vpn_ecmp_support = "enable"

  # Private ASN for BGP sessions with on-premises routers (lab 12).
  amazon_side_asn = 64512

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-tgw" })
}

# Each attachment is billed by the hour whether or not any traffic flows.
resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  for_each = local.create_tgw ? local.tgw_segments : {}

  transit_gateway_id = aws_ec2_transit_gateway.this[0].id
  vpc_id             = local.vpc_ids[each.key]
  subnet_ids         = [aws_subnet.tgw[each.key].id]

  # Explicit rather than inherited, matching the gateway's disabled defaults.
  # The association and propagation resources below do the real work.
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  dns_support = "enable"

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-attach-${each.key}"
    Segment = each.value
  })
}

# -----------------------------------------------------------------------------
# Transit Gateway route tables -- where segmentation lives
# -----------------------------------------------------------------------------
resource "aws_ec2_transit_gateway_route_table" "spoke" {
  count = local.create_tgw ? 1 : 0

  transit_gateway_id = aws_ec2_transit_gateway.this[0].id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-tgw-rt-spoke" })
}

resource "aws_ec2_transit_gateway_route_table" "shared" {
  count = local.create_tgw ? 1 : 0

  transit_gateway_id = aws_ec2_transit_gateway.this[0].id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-tgw-rt-shared" })
}

# ASSOCIATION: which route table this attachment consults when SENDING.
# Exactly one per attachment.
resource "aws_ec2_transit_gateway_route_table_association" "spoke" {
  for_each = local.create_tgw ? local.tgw_spoke_attachments : {}

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke[0].id
}

resource "aws_ec2_transit_gateway_route_table_association" "shared" {
  for_each = local.create_tgw ? local.tgw_shared_attachments : {}

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.shared[0].id
}

# PROPAGATION: which route tables LEARN about this attachment's VPC range.
# Any number per attachment, and completely independent of association.
#
# The spoke table learns ONLY the shared VPC. That is the whole segmentation
# control: shop and dev consult this table, and it contains no route to each
# other, so their traffic is dropped at the gateway.
resource "aws_ec2_transit_gateway_route_table_propagation" "into_spoke_table" {
  for_each = local.create_tgw ? local.tgw_spoke_table_learns : {}

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke[0].id
}

# The shared table learns shop and dev, so the shared VPC can reply to both.
# This is asymmetric with the spoke table above, and that is the point.
resource "aws_ec2_transit_gateway_route_table_propagation" "into_shared_table" {
  for_each = local.create_tgw ? local.tgw_spoke_attachments : {}

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

# -----------------------------------------------------------------------------
# VPC route tables -- one summary route each
#
# Every route table sends the whole supernet to the Transit Gateway. Adding a
# fourth VPC inside the supernet needs no change here at all; whether it can
# be reached is decided by the Transit Gateway route tables.
# -----------------------------------------------------------------------------
resource "aws_route" "to_tgw" {
  for_each = local.create_tgw ? local.tgw_vpc_routes : {}

  route_table_id         = each.value.route_table_id
  destination_cidr_block = var.supernet_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this[0].id

  # The route is rejected until the attachment exists, and Terraform cannot
  # infer the ordering from the arguments alone.
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

check "transit_gateway_is_disabled" {
  assert {
    condition     = local.create_tgw
    error_message = "The Transit Gateway is DISABLED, so the three VPCs are not connected to anything. This is the default because three attachments cost about USD 0.15/hour (USD 110/month). Set acknowledge_costs = true and enable_transit_gateway = true when you are ready to run the lab, and turn it off the same day."
  }
}

output "transit_gateway_id" {
  description = "ID of the Transit Gateway, or null when disabled."
  value       = one(aws_ec2_transit_gateway.this[*].id)
}

output "transit_gateway_route_table_ids" {
  description = "The spoke and shared Transit Gateway route tables."
  value = local.create_tgw ? {
    spoke  = aws_ec2_transit_gateway_route_table.spoke[0].id
    shared = aws_ec2_transit_gateway_route_table.shared[0].id
  } : {}
}

output "verify_transit_gateway" {
  description = "Commands for checking the Transit Gateway. Empty when disabled. The from_* commands run in a shell on the named host."
  value = local.create_tgw ? {
    attachments = "aws ec2 describe-transit-gateway-attachments --filters Name=transit-gateway-id,Values=${aws_ec2_transit_gateway.this[0].id} --region ${var.aws_region} --query 'TransitGatewayAttachments[].{Name:Tags[?Key==`Name`]|[0].Value,State:State,RouteTable:Association.TransitGatewayRouteTableId}' --output table"

    spoke_table_routes  = "aws ec2 search-transit-gateway-routes --transit-gateway-route-table-id ${aws_ec2_transit_gateway_route_table.spoke[0].id} --filters Name=state,Values=active,blackhole --region ${var.aws_region} --query 'Routes[].{Dest:DestinationCidrBlock,Type:Type,State:State}' --output table"
    shared_table_routes = "aws ec2 search-transit-gateway-routes --transit-gateway-route-table-id ${aws_ec2_transit_gateway_route_table.shared[0].id} --filters Name=state,Values=active,blackhole --region ${var.aws_region} --query 'Routes[].{Dest:DestinationCidrBlock,Type:Type,State:State}' --output table"

    from_web_reach_shared     = "curl -s http://${module.other_host["shared"].private_ip}:${local.tools_port}/"
    from_dev_reach_shared     = "curl -s http://${module.other_host["shared"].private_ip}:${local.tools_port}/"
    from_web_cannot_reach_dev = "curl -s --max-time 5 http://${module.other_host["dev"].private_ip}:${local.tools_port}/ || echo 'timed out: no route in the spoke table'"
  } : {}
}
