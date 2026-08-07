locals {
  # AZ names are account-specific: what one account calls ap-southeast-1a is
  # physically a different zone in another account. Resolving them from a data
  # source keeps every lab portable. `opt-in-not-required` excludes Local Zones
  # and Wavelength Zones, which do not support most of the resources here.
  azs      = length(var.availability_zones) > 0 ? var.availability_zones : data.aws_availability_zones.available.names
  az_count = length(local.azs)

  # ---------------------------------------------------------------------------
  # Subnet normalisation
  #
  # Both subnet maps are resolved into one shape carrying the AZ name and, when
  # IPv6 is enabled, a /64 prefix. Anything that cannot be resolved becomes null
  # so that a precondition can produce a readable error instead of an index panic.
  # ---------------------------------------------------------------------------
  all_subnet_keys = sort(concat(keys(var.public_subnets), keys(var.private_subnets)))

  # Deterministic fallback for callers that do not assign IPv6 prefixes by hand.
  default_ipv6_index = { for i, k in local.all_subnet_keys : k => i }

  vpc_ipv6_cidr = var.enable_ipv6 ? aws_vpc.this.ipv6_cidr_block : null

  public_subnets = {
    for k, v in var.public_subnets : k => {
      cidr_block              = v.cidr_block
      az_index                = v.az_index
      map_public_ip_on_launch = v.map_public_ip_on_launch
      availability_zone       = v.az_index < local.az_count ? local.azs[v.az_index] : null
      # An Amazon-provided VPC IPv6 block is always a /56. Adding 8 bits yields
      # the /64 that AWS requires for every subnet -- 256 possible subnets.
      ipv6_cidr_block = var.enable_ipv6 ? cidrsubnet(local.vpc_ipv6_cidr, 8, coalesce(v.ipv6_prefix_index, local.default_ipv6_index[k])) : null
    }
  }

  private_subnets = {
    for k, v in var.private_subnets : k => {
      cidr_block              = v.cidr_block
      az_index                = v.az_index
      map_public_ip_on_launch = false
      availability_zone       = v.az_index < local.az_count ? local.azs[v.az_index] : null
      ipv6_cidr_block         = var.enable_ipv6 ? cidrsubnet(local.vpc_ipv6_cidr, 8, coalesce(v.ipv6_prefix_index, local.default_ipv6_index[k])) : null
    }
  }

  # ---------------------------------------------------------------------------
  # CIDR arithmetic for validation
  #
  # Terraform has no "does CIDR A contain CIDR B" function, so addresses are
  # converted to integers. 10.0.1.0 becomes 10*2^24 + 0*2^16 + 1*2^8 + 0. A
  # block occupies [start, start + size). This is the same arithmetic you do by
  # hand when planning an address space, which is why it is worth reading.
  # ---------------------------------------------------------------------------
  vpc_start = sum([for i, o in split(".", split("/", var.cidr_block)[0]) : tonumber(o) * pow(256, 3 - i)])
  vpc_size  = pow(2, 32 - tonumber(split("/", var.cidr_block)[1]))

  subnet_bounds = {
    for k, v in merge(var.public_subnets, var.private_subnets) : k => {
      start = sum([for i, o in split(".", split("/", v.cidr_block)[0]) : tonumber(o) * pow(256, 3 - i)])
      size  = pow(2, 32 - tonumber(split("/", v.cidr_block)[1]))
      cidr  = v.cidr_block
    }
  }

  subnets_outside_vpc = [
    for k, b in local.subnet_bounds : "${k} (${b.cidr})"
    if b.start < local.vpc_start || (b.start + b.size) > (local.vpc_start + local.vpc_size)
  ]

  # Pairwise overlap check. Two ranges [a, a+n) and [b, b+m) overlap when each
  # starts before the other ends. The `j > i` guard visits each pair once; it
  # compares list indexes rather than key strings because Terraform's `<`
  # operator is numeric only. O(n^2) is irrelevant for a handful of subnets.
  subnet_keys_sorted = sort(keys(local.subnet_bounds))

  overlapping_subnets = flatten([
    for i, ka in local.subnet_keys_sorted : [
      for j, kb in local.subnet_keys_sorted : (
        local.subnet_bounds[ka].start < (local.subnet_bounds[kb].start + local.subnet_bounds[kb].size) &&
        local.subnet_bounds[kb].start < (local.subnet_bounds[ka].start + local.subnet_bounds[ka].size)
      ) ? ["${ka} (${local.subnet_bounds[ka].cidr}) overlaps ${kb} (${local.subnet_bounds[kb].cidr})"] : []
      if j > i
    ]
  ])

  # Derived from the raw variables rather than from local.public_subnets: the
  # latter reads aws_vpc.this.ipv6_cidr_block, and the VPC's own precondition
  # cannot depend on the VPC.
  subnets_with_bad_az = [
    for k, v in merge(var.public_subnets, var.private_subnets) : k
    if v.az_index >= local.az_count
  ]

  # ---------------------------------------------------------------------------
  # NAT gateway placement
  #
  # A NAT gateway must live in a PUBLIC subnet -- it needs a route to the
  # internet gateway for its own outbound traffic. Private subnets then route
  # 0.0.0.0/0 at it. Putting a NAT gateway in a private subnet is a classic
  # mistake that produces a black hole rather than an error.
  # ---------------------------------------------------------------------------
  public_azs_sorted = sort(distinct([for k, v in var.public_subnets : tostring(v.az_index)]))

  # One public subnet per AZ index, chosen deterministically so that re-running
  # Terraform does not move the NAT gateway.
  nat_subnet_by_az = {
    for az in local.public_azs_sorted : az => (
      sort([for k, v in var.public_subnets : k if tostring(v.az_index) == az])[0]
    )
  }

  nat_target_azs = (
    var.nat_gateway_mode == "per_az" ? local.public_azs_sorted :
    var.nat_gateway_mode == "single" ? slice(local.public_azs_sorted, 0, min(1, length(local.public_azs_sorted))) :
    []
  )

  nat_gateways = { for az in local.nat_target_azs : az => local.nat_subnet_by_az[az] }

  # ---------------------------------------------------------------------------
  # Route tables
  #
  # One route table per AZ for private subnets, even when NAT is disabled or
  # single-AZ. It costs nothing, keeps per-AZ routing possible later, and makes
  # the "which NAT does this subnet use" question answerable by looking at one
  # table.
  # ---------------------------------------------------------------------------
  private_azs_sorted = sort(distinct([for k, v in var.private_subnets : tostring(v.az_index)]))

  # Which NAT gateway a given private AZ sends 0.0.0.0/0 to. With mode "single"
  # every AZ shares one gateway, which means cross-AZ data transfer charges for
  # the AZs that do not host it.
  private_az_nat = {
    # The length guard is not defensive noise: when a caller asks for NAT with
    # no public subnets, nat_target_azs is empty. Indexing it would blow up in
    # locals evaluation and hide the precondition on aws_vpc.this, which
    # explains the actual mistake.
    for az in local.private_azs_sorted : az => (
      var.nat_gateway_mode == "none" || length(local.nat_target_azs) == 0 ? null :
      var.nat_gateway_mode == "single" ? local.nat_target_azs[0] :
      contains(local.nat_target_azs, az) ? az : local.nat_target_azs[0]
    )
  }

  create_igw   = var.create_internet_gateway
  create_eoigw = var.enable_ipv6 && var.enable_egress_only_internet_gateway

  tags = merge(var.tags, { Name = var.name })
}
