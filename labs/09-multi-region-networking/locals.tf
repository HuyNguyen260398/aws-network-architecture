locals {
  lab_name    = "09-multi-region-networking"
  name_prefix = "${var.project_name}-lab09"

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

  create_tgw_peering = var.enable_transit_gateway_peering && var.acknowledge_costs

  primary_subnets = {
    "public-a" = {
      cidr_block              = cidrsubnet(var.primary_vpc_cidr, var.subnet_newbits, 0)
      az_index                = 0
      map_public_ip_on_launch = true
    }
  }

  secondary_subnets = {
    "public-a" = {
      cidr_block              = cidrsubnet(var.secondary_vpc_cidr, var.subnet_newbits, 0)
      az_index                = 0
      map_public_ip_on_launch = true
    }
  }

  # Four attachments when Transit Gateway peering is on: one VPC attachment per
  # Region, plus the requester and accepter sides of the peering attachment.
  tgw_attachment_count = local.create_tgw_peering ? 4 : 0

  estimated_hourly_usd = (
    local.tgw_attachment_count * 0.05
    + (var.enable_test_instances ? 2 * (0.0053 + 0.005) : 0)
  )
}
