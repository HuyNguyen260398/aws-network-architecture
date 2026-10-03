# =============================================================================
# VPC peering.
#
# A peering connection joins exactly two VPCs. It is free, has no bandwidth
# limit and no single point of failure. It is also just a possibility: no
# traffic uses it until a route table on EACH side says so.
#
#   shop <-> shared     the shop uses the shared tools
#   dev  <-> shared     so does dev
#   shop  x  dev        nothing. Both are peered with shared, and that does
#                       NOT connect them to each other: peering is not
#                       transitive. Here that is exactly what is wanted.
# =============================================================================

variable "enable_shop_to_dev_peering" {
  description = "Add a third peering connection, directly between the shop and dev. This is the only way to connect two peered VPCs: a full mesh, one connection per pair. Off by default because production and dev should not be connected at all."
  type        = bool
  default     = false
}

locals {
  peerings = merge(
    {
      "shop-shared" = { from = "shop", to = "shared" }
      "dev-shared"  = { from = "dev", to = "shared" }
    },
    var.enable_shop_to_dev_peering ? { "shop-dev" = { from = "shop", to = "dev" } } : {},
  )

  # One route per route table per direction. Six for shop<->shared alone,
  # because the shop has three route tables.
  peering_routes = merge(flatten([
    for key, p in local.peerings : [
      {
        for rt_name, rt_id in local.vpc_route_table_ids[p.from] :
        "${key}:${p.from}-${rt_name}" => { route_table_id = rt_id, destination = local.vpc_cidrs[p.to], peering = key }
      },
      {
        for rt_name, rt_id in local.vpc_route_table_ids[p.to] :
        "${key}:${p.to}-${rt_name}" => { route_table_id = rt_id, destination = local.vpc_cidrs[p.from], peering = key }
      },
    ]
  ])...)
}

resource "aws_vpc_peering_connection" "this" {
  for_each = local.peerings

  # Requester and accepter. Same account and Region here, so the request can
  # accept itself; across accounts the other side must accept it explicitly.
  vpc_id      = local.vpc_ids[each.value.from]
  peer_vpc_id = local.vpc_ids[each.value.to]
  auto_accept = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-pcx-${each.key}" })
}

# Lets each side resolve the other's private DNS names to PRIVATE addresses.
# Without it, a public DNS name resolves to the public address and the traffic
# leaves through the internet gateway instead of the peering connection.
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

# THE mechanism. Delete one of these and that subnet's traffic to the other
# VPC is dropped, while the peering connection still shows "active".
resource "aws_route" "peering" {
  for_each = local.peering_routes

  route_table_id            = each.value.route_table_id
  destination_cidr_block    = each.value.destination
  vpc_peering_connection_id = aws_vpc_peering_connection.this[each.value.peering].id
}

check "peering_is_not_transitive" {
  assert {
    condition     = var.enable_shop_to_dev_peering
    error_message = "The shop and dev are both peered with shared, and neither can reach the other. This is expected: VPC peering is not transitive. It is also the right outcome for production and dev. Set enable_shop_to_dev_peering = true to see the full-mesh alternative -- then count how many connections ten VPCs would need."
  }
}

output "peering_connection_ids" {
  description = "Map of peering name to connection ID."
  value       = { for key, pcx in aws_vpc_peering_connection.this : key => pcx.id }
}

output "verify_peering" {
  description = "Commands for checking peering. The from_* commands run in a shell on the named host."
  value = {
    connections = "aws ec2 describe-vpc-peering-connections --filters Name=tag:Project,Values=${var.project_name} --region ${var.aws_region} --query 'VpcPeeringConnections[].{Name:Tags[?Key==`Name`]|[0].Value,Status:Status.Code,Requester:RequesterVpcInfo.CidrBlock,Accepter:AccepterVpcInfo.CidrBlock}' --output table"

    routes_using_peering = "aws ec2 describe-route-tables --filters Name=tag:Project,Values=${var.project_name} --region ${var.aws_region} --query 'RouteTables[].{Name:Tags[?Key==`Name`]|[0].Value,Peered:Routes[?VpcPeeringConnectionId!=`null`].DestinationCidrBlock}' --output table"

    from_web_reach_shared     = "curl -s http://${module.other_host["shared"].private_ip}:${local.tools_port}/"
    from_dev_reach_shared     = "curl -s http://${module.other_host["shared"].private_ip}:${local.tools_port}/"
    from_web_cannot_reach_dev = "curl -s --max-time 5 http://${module.other_host["dev"].private_ip}:${local.tools_port}/ || echo 'timed out: peering is not transitive'"
  }
}
