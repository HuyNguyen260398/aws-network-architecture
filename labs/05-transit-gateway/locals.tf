locals {
  lab_name    = "05-transit-gateway"
  name_prefix = "${var.project_name}-lab05"

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

  create_tgw = var.enable_transit_gateway && var.acknowledge_costs

  spokes = {
    prod = {
      cidr    = var.prod_vpc_cidr
      segment = "spoke"
    }
    dev = {
      cidr    = var.dev_vpc_cidr
      segment = "spoke"
    }
    shared = {
      cidr    = var.shared_vpc_cidr
      segment = "shared"
    }
  }

  # ---------------------------------------------------------------------------
  # Subnet layout
  #
  # Each VPC gets two subnets:
  #
  #   public-a    /24, holds the test instance. Public so the instance can reach
  #               Systems Manager over an internet gateway; all Transit Gateway
  #               tests use private addresses.
  #   tgw-a       /28, holds NOTHING but the Transit Gateway attachment ENI.
  #
  # The dedicated attachment subnet is AWS's documented recommendation and it is
  # worth following. An attachment ENI in a workload subnet consumes addresses
  # from it, and -- more importantly -- the network ACL on that subnet then
  # applies to every packet transiting the gateway, which is an extremely
  # confusing place to discover a dropped connection.
  # ---------------------------------------------------------------------------
  tgw_subnet_newbits = 12

  # Placed at the very top of each VPC range, well away from the workload
  # subnets carved from the bottom.
  tgw_subnet_netnum = pow(2, local.tgw_subnet_newbits) - 1

  # ---------------------------------------------------------------------------
  # Segmentation
  #
  # Two Transit Gateway route tables:
  #
  #   spoke   associated with prod and dev. Learns ONLY the shared VPC, so prod
  #           and dev can each reach shared services and NOT each other.
  #   shared  associated with shared. Learns prod and dev, so shared services
  #           can reply to both.
  #
  # ASSOCIATION decides which route table an attachment CONSULTS when sending.
  # PROPAGATION decides which route tables LEARN about an attachment.
  # An attachment has exactly one association and any number of propagations.
  # Getting these two backwards is the single most common Transit Gateway
  # mistake, and it produces one-way connectivity rather than an error.
  # ---------------------------------------------------------------------------
  spoke_attachments  = { for k, v in local.spokes : k => v if v.segment == "spoke" }
  shared_attachments = { for k, v in local.spokes : k => v if v.segment == "shared" }

  # What the spoke route table learns. Shared always; prod additionally when the
  # segmentation is deliberately collapsed.
  spoke_rt_propagations = merge(
    local.shared_attachments,
    var.allow_dev_to_prod ? { prod = local.spokes["prod"] } : {},
  )

  attachment_count     = local.create_tgw ? length(local.spokes) : 0
  estimated_hourly_usd = local.attachment_count * 0.05 + (var.enable_test_instances ? length(local.spokes) * (0.0053 + 0.005) : 0)
}
