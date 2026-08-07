# =============================================================================
# Lab 01 -- VPC fundamentals
#
# The smallest complete VPC: an address range, subnets in more than one
# Availability Zone, route tables, an internet gateway, and the two filtering
# mechanisms AWS gives you.
#
# NOTHING HERE COSTS MONEY. There is no NAT gateway, no EC2 instance, no
# Elastic IP, no endpoint. Every resource in this lab is free to create and free
# to keep. That is deliberate: the first lab should be about understanding the
# primitives, not about watching a meter.
# =============================================================================

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# A Region is a geographic area; an Availability Zone is one or more discrete
# data centres inside it with independent power, cooling and networking. Subnets
# live in exactly one AZ and cannot span zones, which is why a highly available
# design needs a subnet per zone rather than one big subnet.
check "enough_availability_zones" {
  assert {
    condition     = length(data.aws_availability_zones.available.names) >= var.az_count
    error_message = "az_count is ${var.az_count} but ${var.aws_region} has only ${length(data.aws_availability_zones.available.names)} Availability Zones that do not require opt-in."
  }
}

module "vpc" {
  source = "../../modules/vpc"

  name       = local.name_prefix
  cidr_block = var.vpc_cidr

  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  # Free. The gateway itself costs nothing; you pay only for data that crosses it.
  create_internet_gateway = true

  # A NAT gateway would cost about USD 43/month. Lab 02 introduces it, behind an
  # explicit opt-in. Here the private subnets have NO default route, which makes
  # them genuinely isolated -- and demonstrates the point of this lab.
  nat_gateway_mode = "none"

  enable_ipv6                         = var.enable_ipv6
  enable_egress_only_internet_gateway = var.enable_ipv6

  tags = local.common_tags
}

# =============================================================================
# Security groups -- stateful, instance-level, allow-only
# =============================================================================
#
# A security group is attached to an elastic network interface, not to a subnet.
# It is STATEFUL: if a request is allowed in, the reply is allowed out
# automatically, whatever the outbound rules say. There is no deny rule -- a
# security group can only permit, and anything not permitted is dropped.
#
# No instances are created here. These groups exist so you can read them, and so
# later labs have something to reference.

resource "aws_security_group" "web" {
  name_prefix = "${local.name_prefix}-web-"
  description = "Public-facing tier: HTTPS from the internet"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-web" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "web_https" {
  security_group_id = aws_security_group.web.id
  description       = "HTTPS from anywhere"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-web-https" })
}

resource "aws_vpc_security_group_ingress_rule" "web_https_v6" {
  count = var.enable_ipv6 ? 1 : 0

  security_group_id = aws_security_group.web.id
  description       = "HTTPS from anywhere over IPv6"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv6         = "::/0"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-web-https-v6" })
}

resource "aws_vpc_security_group_egress_rule" "web_all" {
  security_group_id = aws_security_group.web.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-web-egress" })
}

resource "aws_security_group" "app" {
  name_prefix = "${local.name_prefix}-app-"
  description = "Private tier: application port from the web tier only"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-app" })

  lifecycle {
    create_before_destroy = true
  }
}

# Referencing a security group instead of a CIDR is the single most useful
# security group technique. The rule keeps working as instances are added,
# removed, or re-addressed, because it names an identity rather than a range.
resource "aws_vpc_security_group_ingress_rule" "app_from_web" {
  security_group_id = aws_security_group.app.id
  description       = "Application port from the web tier security group"
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080

  referenced_security_group_id = aws_security_group.web.id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-app-from-web" })
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-app-egress" })
}

# =============================================================================
# Network ACL -- stateless, subnet-level, allow and deny
# =============================================================================
#
# A network ACL is attached to a SUBNET and evaluates every packet entering or
# leaving it. It is STATELESS: the reply to an allowed request is evaluated
# independently, so a working connection needs rules in BOTH directions. It
# supports DENY, which security groups do not, and rules are processed in
# numbered order -- the first match wins and evaluation stops.
#
# The ephemeral-port rules below are the part people forget. Without them,
# requests leave successfully and replies are silently dropped, which looks
# exactly like a routing problem.

resource "aws_network_acl" "private" {
  vpc_id     = module.vpc.vpc_id
  subnet_ids = values(module.vpc.private_subnet_ids)

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-nacl-private" })
}

resource "aws_network_acl_rule" "private_inbound_vpc" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 100
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
}

# Return traffic for connections this subnet initiated. The kernel picks a
# source port from the ephemeral range for each outbound connection, and the
# reply arrives addressed to that port. 1024-65535 covers every operating
# system's range; Linux itself uses 32768-60999.
resource "aws_network_acl_rule" "private_inbound_ephemeral" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "private_outbound_all" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

# An explicit deny that will never be reached, because rule 100 above already
# allows everything outbound. It is here so you can see the ordering rule: move
# this to rule number 50 and the allow at 100 becomes unreachable. Rules are
# evaluated lowest number first and evaluation STOPS at the first match.
resource "aws_network_acl_rule" "private_outbound_deny_example" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 200
  egress         = true
  protocol       = "tcp"
  rule_action    = "deny"
  cidr_block     = "192.0.2.0/24"
  from_port      = 0
  to_port        = 65535
}

resource "aws_network_acl_rule" "private_inbound_ipv6_vpc" {
  count = var.enable_ipv6 ? 1 : 0

  network_acl_id  = aws_network_acl.private.id
  rule_number     = 150
  egress          = false
  protocol        = "-1"
  rule_action     = "allow"
  ipv6_cidr_block = module.vpc.vpc_ipv6_cidr_block
}

resource "aws_network_acl_rule" "private_outbound_ipv6_all" {
  count = var.enable_ipv6 ? 1 : 0

  network_acl_id  = aws_network_acl.private.id
  rule_number     = 150
  egress          = true
  protocol        = "-1"
  rule_action     = "allow"
  ipv6_cidr_block = "::/0"
}
