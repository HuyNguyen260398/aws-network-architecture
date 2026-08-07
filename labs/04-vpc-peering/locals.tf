locals {
  lab_name    = "04-vpc-peering"
  name_prefix = "${var.project_name}-lab04"

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

  # Each VPC gets a single public subnet in one Availability Zone. That is all
  # this lab needs: peering is about routing BETWEEN VPCs, and multi-AZ layout
  # inside them adds cost without adding a lesson.
  #
  # The subnets are public so the instances can reach Systems Manager over an
  # internet gateway. All peering tests use PRIVATE addresses.
  vpcs = {
    a = { cidr = var.vpc_a_cidr, create = true }
    b = { cidr = var.vpc_b_cidr, create = true }
    c = { cidr = var.vpc_c_cidr, create = var.enable_vpc_c }
  }

  active_vpcs = { for k, v in local.vpcs : k => v if v.create }

  # Which VPC pairs are peered. The keys become resource addresses.
  peerings = merge(
    {
      "a-b" = { from = "a", to = "b" }
    },
    var.enable_vpc_c ? { "a-c" = { from = "a", to = "c" } } : {},
    var.enable_b_to_c_peering ? { "b-c" = { from = "b", to = "c" } } : {},
  )

  # A peering connection on its own moves no packets. Each side needs a route
  # entry pointing the OTHER VPC's CIDR at the connection. Both directions are
  # required -- a one-sided route produces traffic that arrives and cannot reply,
  # which looks like a firewall problem.
  peering_routes = merge([
    for key, p in local.peerings : {
      "${key}-${p.from}-to-${p.to}" = {
        peering_key = key
        source_vpc  = p.from
        dest_vpc    = p.to
        dest_cidr   = local.vpcs[p.to].cidr
      }
      "${key}-${p.to}-to-${p.from}" = {
        peering_key = key
        source_vpc  = p.to
        dest_vpc    = p.from
        dest_cidr   = local.vpcs[p.from].cidr
      }
    }
  ]...)

  estimated_hourly_usd = var.enable_test_instances ? length(local.active_vpcs) * (0.0053 + 0.005) : 0
}
