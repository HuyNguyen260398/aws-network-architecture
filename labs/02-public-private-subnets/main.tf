# =============================================================================
# Lab 02 -- Public and private subnets
#
# Lab 01 established that a subnet is public because of a route. This lab makes
# that concrete with instances you can actually log into, and introduces the
# three ways a private subnet can be given outbound internet access:
#
#   1. Nothing            free, and genuinely isolated (the default here)
#   2. NAT gateway        ~USD 43/month, IPv4 outbound only        (opt-in)
#   3. Egress-only IGW    FREE, IPv6 outbound only                 (opt-in)
#
# There is no IPv6 NAT on AWS, and there never will be -- every IPv6 address is
# globally routable, so the "hide behind one address" half of NAT has no
# meaning. The egress-only internet gateway provides only the other half:
# outbound connections succeed, unsolicited inbound ones are dropped.
# =============================================================================

module "vpc" {
  source = "../../modules/vpc"

  name       = local.name_prefix
  cidr_block = var.vpc_cidr

  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  create_internet_gateway = true
  nat_gateway_mode        = local.nat_gateway_mode

  enable_ipv6                         = var.enable_ipv6
  enable_egress_only_internet_gateway = local.enable_eoigw

  tags = local.common_tags
}

# =============================================================================
# Test instances
#
# Both are reached through Session Manager. Neither has an SSH rule, a key pair,
# or an inbound rule of any kind -- the SSM agent dials OUT to the Systems
# Manager service, and security groups are stateful, so the reply comes back
# without an explicit rule.
#
# The two instances differ in exactly one interesting way: whether their subnet
# has a route to the internet. Watch which one registers with Systems Manager.
# =============================================================================

# In a PUBLIC subnet with a public IPv4 address. Its route table sends 0.0.0.0/0
# to the internet gateway, so the SSM agent reaches Systems Manager directly.
# This works with no NAT gateway and no VPC endpoints -- it costs the price of
# the public IP address and nothing else.
module "public_instance" {
  count  = var.enable_test_instances ? 1 : 0
  source = "../../modules/test-instance"

  name          = "${local.name_prefix}-public"
  vpc_id        = module.vpc.vpc_id
  subnet_id     = module.vpc.public_subnet_ids[local.first_public_subnet_key]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  # Required for this instance to reach the SSM endpoints over the IGW.
  associate_public_ip_address = true

  # Allow ping from inside the VPC so the private instance can be tested
  # against it. ICMP "from_port" is the ICMP TYPE (8 = echo request) and
  # "to_port" is the ICMP CODE (-1 = any) -- they are not port numbers.
  ingress_rules = {
    icmp_from_vpc = {
      description = "ICMP echo request from within the VPC"
      ip_protocol = "icmp"
      from_port   = 8
      to_port     = -1
      cidr_ipv4   = var.vpc_cidr
    }
  }

  tags = merge(local.common_tags, { Tier = "public" })
}

# In a PRIVATE subnet with no public IP address.
#
# Whether this instance appears in Systems Manager depends entirely on
# enable_nat_gateway:
#   false -> the private route table has no default route. The SSM agent cannot
#            reach the service, the instance never registers, and
#            'aws ssm start-session' fails with TargetNotConnected.
#   true  -> 0.0.0.0/0 points at the NAT gateway and it registers in a minute.
#
# Lab 03 shows the third option: interface VPC endpoints, which let this work
# with no internet access at all and cost about half as much as a NAT gateway.
module "private_instance" {
  count  = var.enable_test_instances ? 1 : 0
  source = "../../modules/test-instance"

  name          = "${local.name_prefix}-private"
  vpc_id        = module.vpc.vpc_id
  subnet_id     = module.vpc.private_subnet_ids[local.first_private_subnet_key]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  associate_public_ip_address = false

  ingress_rules = {
    icmp_from_vpc = {
      description = "ICMP echo request from within the VPC"
      ip_protocol = "icmp"
      from_port   = 8
      to_port     = -1
      cidr_ipv4   = var.vpc_cidr
    }
  }

  tags = merge(local.common_tags, { Tier = "private" })
}

# A check block reports a warning during plan and apply rather than failing.
# This one is a deliberate teaching prompt: the configuration is valid, but the
# private instance will not be reachable, and it is better to say so up front
# than to let someone spend twenty minutes debugging Session Manager.
check "private_instance_can_reach_ssm" {
  assert {
    condition     = !var.enable_test_instances || var.enable_nat_gateway
    error_message = "The private instance has no route to the internet, so its SSM agent cannot register and 'aws ssm start-session' will fail with TargetNotConnected. That is expected and is part of the lab. Set enable_nat_gateway = true (and acknowledge_costs = true) to give it a path, or see lab 03 for the cheaper VPC endpoint approach."
  }
}
