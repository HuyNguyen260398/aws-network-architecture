locals {
  lab_name    = "01-vpc-fundamentals"
  name_prefix = "${var.project_name}-lab01"

  common_tags = merge(
    {
      Project     = var.project_name
      Lab         = local.lab_name
      Environment = "learning"
      ManagedBy   = "terraform"
      # Everything in a lab is disposable. The tag makes that explicit to
      # anyone who finds these resources later and to any cleanup automation.
      Lifecycle = "ephemeral"
    },
    var.additional_tags,
  )

  # Human-friendly suffixes: public-a, public-b, ... rather than public-0.
  az_letters = ["a", "b", "c", "d"]

  # ---------------------------------------------------------------------------
  # CIDR carving
  #
  # cidrsubnet(prefix, newbits, netnum) extends a prefix by `newbits` and picks
  # the `netnum`-th resulting block:
  #
  #   cidrsubnet("10.10.0.0/16", 8, 0)   -> 10.10.0.0/24
  #   cidrsubnet("10.10.0.0/16", 8, 1)   -> 10.10.1.0/24
  #   cidrsubnet("10.10.0.0/16", 8, 128) -> 10.10.128.0/24
  #
  # Public subnets take blocks from the bottom of the range, private subnets
  # from the top. That leaves a contiguous gap in the middle for growth, which
  # is what you want when a VPC CIDR can never be widened.
  # ---------------------------------------------------------------------------
  private_netnum_offset = floor(pow(2, var.subnet_newbits) / 2)

  public_cidrs = length(var.public_subnet_cidrs) > 0 ? var.public_subnet_cidrs : [
    for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, var.subnet_newbits, i)
  ]

  private_cidrs = length(var.private_subnet_cidrs) > 0 ? var.private_subnet_cidrs : [
    for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, var.subnet_newbits, local.private_netnum_offset + i)
  ]

  public_subnets = {
    for i, cidr in local.public_cidrs : "public-${local.az_letters[i]}" => {
      cidr_block = cidr
      az_index   = i
      # Deliberately false. This lab creates no instances, and an automatically
      # assigned public IPv4 address is billed hourly. Lab 02 turns it on and
      # explains what changes.
      map_public_ip_on_launch = false
    }
  }

  private_subnets = {
    for i, cidr in local.private_cidrs : "private-${local.az_letters[i]}" => {
      cidr_block = cidr
      az_index   = i
    }
  }
}
