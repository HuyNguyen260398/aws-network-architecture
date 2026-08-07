# =============================================================================
# Lab 09 -- Multi-Region networking
#
#   ap-southeast-1                        ap-northeast-1
#   VPC 10.90.0.0/16  <--- peering --->   VPC 10.91.0.0/16
#
# A Region is the hardest boundary in AWS. Nothing crosses it implicitly: not
# routing, not security group references, not a private hosted zone's default
# behaviour, not a Transit Gateway's route table. Every inter-Region path is
# something you deliberately built.
#
# What actually changes when you cross a Region boundary:
#   - Latency stops being negligible. Singapore to Tokyo is roughly 70 ms round
#     trip, and no amount of network design removes the speed of light.
#   - Data transfer is charged in both directions, at higher rates than
#     cross-AZ traffic.
#   - Security group references stop working. You must use CIDRs.
#   - AZ names mean nothing across Regions.
#
# COSTS
#   Inter-Region VPC peering    FREE to create; ~USD 0.02/GB each way
#   Transit Gateway peering     ~USD 0.05/attachment-hour x 4        (opt-in)
#   Route 53 health checks      USD 0.50/month each                  (opt-in)
# =============================================================================

module "primary_vpc" {
  source = "../../modules/vpc"

  name       = "${local.name_prefix}-primary"
  cidr_block = var.primary_vpc_cidr

  public_subnets          = local.primary_subnets
  create_internet_gateway = true
  nat_gateway_mode        = "none"

  tags = merge(local.common_tags, { Region = var.primary_region, Role = "primary" })
}

module "secondary_vpc" {
  source = "../../modules/vpc"

  providers = {
    aws = aws.secondary
  }

  name       = "${local.name_prefix}-secondary"
  cidr_block = var.secondary_vpc_cidr

  public_subnets          = local.secondary_subnets
  create_internet_gateway = true
  nat_gateway_mode        = "none"

  tags = merge(local.common_tags, { Region = var.secondary_region, Role = "secondary" })
}

# =============================================================================
# Inter-Region VPC peering -- free to create
#
# Structurally identical to same-Region peering, with two differences that
# matter:
#   1. The accepter is a SEPARATE resource using the other Region's provider.
#      auto_accept does not work across Regions.
#   2. DNS resolution across the peering must be enabled on the ACCEPTER side,
#      via aws_vpc_peering_connection_options with the accepter's provider.
# =============================================================================
resource "aws_vpc_peering_connection" "inter_region" {
  count = var.enable_vpc_peering ? 1 : 0

  vpc_id      = module.primary_vpc.vpc_id
  peer_vpc_id = module.secondary_vpc.vpc_id
  peer_region = var.secondary_region

  # Cannot be true for a cross-Region peering. The accepter resource below is
  # what completes it, and it must run against the other Region's provider.
  auto_accept = false

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-pcx" })
}

resource "aws_vpc_peering_connection_accepter" "inter_region" {
  count = var.enable_vpc_peering ? 1 : 0

  provider = aws.secondary

  vpc_peering_connection_id = aws_vpc_peering_connection.inter_region[0].id
  auto_accept               = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-pcx-accepter" })
}

# Peering options are set per side, each with its own provider. Splitting them
# is not stylistic -- the requester options can only be set from the requester's
# Region, and the same for the accepter.
resource "aws_vpc_peering_connection_options" "requester" {
  count = var.enable_vpc_peering ? 1 : 0

  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.inter_region[0].id

  requester {
    allow_remote_vpc_dns_resolution = true
  }
}

resource "aws_vpc_peering_connection_options" "accepter" {
  count = var.enable_vpc_peering ? 1 : 0

  provider = aws.secondary

  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.inter_region[0].id

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
}

# Routes, on both sides. Same rule as same-Region peering: the connection is
# only a permission, and a missing route on one side produces a timeout that
# looks like a firewall problem.
resource "aws_route" "primary_to_secondary" {
  count = var.enable_vpc_peering ? 1 : 0

  route_table_id            = module.primary_vpc.public_route_table_id
  destination_cidr_block    = var.secondary_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.inter_region[0].id
}

resource "aws_route" "secondary_to_primary" {
  count = var.enable_vpc_peering ? 1 : 0

  provider = aws.secondary

  route_table_id            = module.secondary_vpc.public_route_table_id
  destination_cidr_block    = var.primary_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.inter_region[0].id

  depends_on = [aws_vpc_peering_connection_accepter.inter_region]
}

# =============================================================================
# Transit Gateway peering -- opt-in, ~USD 0.20/hour
#
# The scalable version. Each Region gets a Transit Gateway; the gateways peer.
# Every VPC attached to either gateway can then reach every VPC attached to the
# other, without a peering connection per VPC pair.
#
# One important limitation: a Transit Gateway peering attachment does NOT
# propagate routes. Every prefix must be added as a STATIC route in the Transit
# Gateway route table on both sides. This surprises people who expect the same
# propagation behaviour as a VPC attachment.
# =============================================================================
resource "aws_ec2_transit_gateway" "primary" {
  count = local.create_tgw_peering ? 1 : 0

  description     = "${local.name_prefix} primary"
  amazon_side_asn = 64512

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-tgw-primary" })
}

resource "aws_ec2_transit_gateway" "secondary" {
  count = local.create_tgw_peering ? 1 : 0

  provider = aws.secondary

  description = "${local.name_prefix} secondary"

  # Must differ from the primary gateway's ASN. Two gateways sharing an ASN
  # cannot peer.
  amazon_side_asn = 64513

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-tgw-secondary" })
}

resource "aws_ec2_transit_gateway_vpc_attachment" "primary" {
  count = local.create_tgw_peering ? 1 : 0

  transit_gateway_id = aws_ec2_transit_gateway.primary[0].id
  vpc_id             = module.primary_vpc.vpc_id
  subnet_ids         = [module.primary_vpc.public_subnet_ids["public-a"]]

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-tgw-attach-primary" })
}

resource "aws_ec2_transit_gateway_vpc_attachment" "secondary" {
  count = local.create_tgw_peering ? 1 : 0

  provider = aws.secondary

  transit_gateway_id = aws_ec2_transit_gateway.secondary[0].id
  vpc_id             = module.secondary_vpc.vpc_id
  subnet_ids         = [module.secondary_vpc.public_subnet_ids["public-a"]]

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-tgw-attach-secondary" })
}

resource "aws_ec2_transit_gateway_peering_attachment" "this" {
  count = local.create_tgw_peering ? 1 : 0

  transit_gateway_id      = aws_ec2_transit_gateway.primary[0].id
  peer_transit_gateway_id = aws_ec2_transit_gateway.secondary[0].id
  peer_region             = var.secondary_region

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-tgw-peering" })
}

resource "aws_ec2_transit_gateway_peering_attachment_accepter" "this" {
  count = local.create_tgw_peering ? 1 : 0

  provider = aws.secondary

  transit_gateway_attachment_id = aws_ec2_transit_gateway_peering_attachment.this[0].id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-tgw-peering-accepter" })
}

# STATIC routes, because a peering attachment does not propagate. This is the
# single most common Transit Gateway peering mistake: the attachment shows
# 'available', and nothing routes, because everyone expected propagation.
resource "aws_ec2_transit_gateway_route" "primary_to_secondary" {
  count = local.create_tgw_peering ? 1 : 0

  destination_cidr_block         = var.secondary_vpc_cidr
  transit_gateway_route_table_id = aws_ec2_transit_gateway.primary[0].association_default_route_table_id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.this[0].id

  depends_on = [aws_ec2_transit_gateway_peering_attachment_accepter.this]
}

resource "aws_ec2_transit_gateway_route" "secondary_to_primary" {
  count = local.create_tgw_peering ? 1 : 0

  provider = aws.secondary

  destination_cidr_block         = var.primary_vpc_cidr
  transit_gateway_route_table_id = aws_ec2_transit_gateway.secondary[0].association_default_route_table_id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.this[0].id

  depends_on = [aws_ec2_transit_gateway_peering_attachment_accepter.this]
}

# =============================================================================
# Test instances -- one per Region
# =============================================================================
module "primary_instance" {
  count  = var.enable_test_instances ? 1 : 0
  source = "../../modules/test-instance"

  name          = "${local.name_prefix}-primary"
  vpc_id        = module.primary_vpc.vpc_id
  subnet_id     = module.primary_vpc.public_subnet_ids["public-a"]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  associate_public_ip_address = true

  # CIDRs, not security group references. A security group in one Region cannot
  # reference one in another Region -- security group IDs are Regional, and this
  # is a hard limitation of inter-Region peering.
  ingress_rules = {
    icmp_from_secondary = {
      description = "ICMP echo request from the secondary Region over the peering connection"
      ip_protocol = "icmp"
      from_port   = 8
      to_port     = -1
      cidr_ipv4   = var.secondary_vpc_cidr
    }
    icmp_local = {
      description = "ICMP echo request from within this VPC"
      ip_protocol = "icmp"
      from_port   = 8
      to_port     = -1
      cidr_ipv4   = var.primary_vpc_cidr
    }
  }

  tags = merge(local.common_tags, { Region = var.primary_region, Role = "primary" })
}

module "secondary_instance" {
  count  = var.enable_test_instances ? 1 : 0
  source = "../../modules/test-instance"

  providers = {
    aws = aws.secondary
  }

  name          = "${local.name_prefix}-secondary"
  vpc_id        = module.secondary_vpc.vpc_id
  subnet_id     = module.secondary_vpc.public_subnet_ids["public-a"]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  associate_public_ip_address = true

  ingress_rules = {
    icmp_from_primary = {
      description = "ICMP echo request from the primary Region over the peering connection"
      ip_protocol = "icmp"
      from_port   = 8
      to_port     = -1
      cidr_ipv4   = var.primary_vpc_cidr
    }
    icmp_local = {
      description = "ICMP echo request from within this VPC"
      ip_protocol = "icmp"
      from_port   = 8
      to_port     = -1
      cidr_ipv4   = var.secondary_vpc_cidr
    }
  }

  tags = merge(local.common_tags, { Region = var.secondary_region, Role = "secondary" })
}

# =============================================================================
# Route 53 health checks -- opt-in, USD 0.50/month each
#
# Health checks are the mechanism behind failover routing: Route 53 stops
# returning a record when its associated health check fails. They are also
# useful on their own as a global, outside-in liveness probe -- Route 53 checks
# from multiple Regions, so a check that fails is not a local network glitch.
#
# The routing POLICIES that consume them (failover, latency, geolocation,
# weighted) need a real domain you control, which a lab cannot assume. The
# README explains what each policy does with these checks.
# =============================================================================
# CLOUDWATCH_METRIC health checks rather than the more familiar HTTP or TCP
# kind. An endpoint health check would need an inbound port open to Route 53's
# health checkers on the public internet, and this repository does not open
# inbound ports on lab instances. A CloudWatch-metric check watches the
# instance's own EC2 status check instead: no listener, no inbound rule, and a
# genuinely meaningful signal.
resource "aws_cloudwatch_metric_alarm" "primary_instance" {
  count = var.enable_route53_health_checks && var.enable_test_instances ? 1 : 0

  alarm_name          = "${local.name_prefix}-primary-status"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "EC2 status check for the primary Region instance"

  dimensions = {
    InstanceId = module.primary_instance[0].instance_id
  }

  # Route 53 treats INSUFFICIENT_DATA according to the health check's setting
  # below, so an alarm with no data does not silently mean "unhealthy".
  treat_missing_data = "notBreaching"

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "secondary_instance" {
  count = var.enable_route53_health_checks && var.enable_test_instances ? 1 : 0

  provider = aws.secondary

  alarm_name          = "${local.name_prefix}-secondary-status"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "EC2 status check for the secondary Region instance"

  dimensions = {
    InstanceId = module.secondary_instance[0].instance_id
  }

  treat_missing_data = "notBreaching"

  tags = local.common_tags
}

resource "aws_route53_health_check" "primary" {
  count = var.enable_route53_health_checks && var.enable_test_instances ? 1 : 0

  type                            = "CLOUDWATCH_METRIC"
  cloudwatch_alarm_name           = aws_cloudwatch_metric_alarm.primary_instance[0].alarm_name
  cloudwatch_alarm_region         = var.primary_region
  insufficient_data_health_status = "Healthy"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-hc-primary" })
}

resource "aws_route53_health_check" "secondary" {
  count = var.enable_route53_health_checks && var.enable_test_instances ? 1 : 0

  type                            = "CLOUDWATCH_METRIC"
  cloudwatch_alarm_name           = aws_cloudwatch_metric_alarm.secondary_instance[0].alarm_name
  cloudwatch_alarm_region         = var.secondary_region
  insufficient_data_health_status = "Healthy"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-hc-secondary" })
}

check "regions_are_different" {
  assert {
    condition     = var.primary_region != var.secondary_region
    error_message = "primary_region and secondary_region are the same. Nothing in this lab is inter-Region unless they differ."
  }
}
