# =============================================================================
# A second Region.
#
# Everything so far lives in one Region. A Region is a hard boundary: a VPC
# cannot span two, a subnet cannot, and nothing in one is reachable from the
# other by default. This lab adds a disaster-recovery (DR) copy of the shop's
# frontend in a second Region and connects the two.
#
#   inter-Region VPC peering    free to create, billed per GB. Traffic stays
#                               on the AWS backbone and is encrypted.
#   Transit Gateway peering     opt-in. Joins the lab 10 hub to a hub in the
#                               DR Region. Static routes only.
#   DNS failover                opt-in. The control that actually moves users
#                               from one Region to the other.
# =============================================================================

variable "dr_region" {
  description = "The second Region. Must differ from aws_region."
  type        = string
  default     = "ap-northeast-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.dr_region))
    error_message = "dr_region must look like an AWS Region identifier, for example ap-northeast-1."
  }
}

variable "dr_vpc_cidr" {
  description = "IPv4 range of the DR VPC. Inside the supernet and overlapping nothing, exactly like a VPC in the first Region: private addresses know nothing about Regions."
  type        = string
  default     = "10.110.0.0/16"

  validation {
    condition     = can(cidrhost(var.dr_vpc_cidr, 0)) && cidrhost(var.dr_vpc_cidr, 0) == split("/", var.dr_vpc_cidr)[0] && can(regex("^.*/16$", var.dr_vpc_cidr))
    error_message = "dr_vpc_cidr must be a valid /16 network address."
  }
}

variable "enable_inter_region_peering" {
  description = "Peer the shop VPC with the DR VPC. Free to create; data crossing it is billed at the inter-Region rate, about USD 0.09/GB out of ap-southeast-1."
  type        = bool
  default     = true
}

variable "enable_transit_gateway_peering" {
  description = <<-EOT
    Create a Transit Gateway in the DR Region, attach the DR VPC, and peer it
    with the lab 10 Transit Gateway.

    COST: two more attachments (the DR VPC and the peering) at about
    USD 0.05/hour each, on top of lab 10's three -- USD 0.25/hour in total.

    Requires enable_transit_gateway. While enable_inter_region_peering is also
    true the VPC peering route is more specific and still wins; turn that off
    to send traffic through the gateways instead.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_transit_gateway_peering || (var.acknowledge_costs && var.enable_transit_gateway)
    error_message = "enable_transit_gateway_peering requires acknowledge_costs = true and enable_transit_gateway = true."
  }
}

variable "enable_dns_failover" {
  description = "Create Route 53 failover records for global.<shop_record_name>.<public_zone_name>: the primary Region while its health check passes, the DR Region when it fails. Requires public_zone_name. A health check is about USD 0.50/month."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_dns_failover || var.public_zone_name != null
    error_message = "enable_dns_failover requires public_zone_name: failover is a DNS answer, so there has to be a zone to put it in."
  }
}

locals {
  create_tgw_peering = var.enable_transit_gateway_peering && local.create_tgw

  # The shop endpoint a client or a health check connects to in the primary
  # Region: the load balancer if there is one, otherwise the web server.
  primary_endpoint_is_alb = local.load_balancer_enabled
}

check "regions_are_different" {
  assert {
    condition     = var.aws_region != var.dr_region
    error_message = "aws_region and dr_region are the same. Nothing in this lab is inter-Region unless they differ."
  }
}

# -----------------------------------------------------------------------------
# The DR Region
# -----------------------------------------------------------------------------
module "dr_vpc" {
  source = "../../modules/vpc"

  providers = {
    aws = aws.dr
  }

  name       = "${local.name_prefix}-dr"
  cidr_block = var.dr_vpc_cidr

  public_subnets = {
    "public-a" = {
      cidr_block              = cidrsubnet(var.dr_vpc_cidr, 8, 0)
      az_index                = 0
      map_public_ip_on_launch = true
    }
  }
  create_internet_gateway = true

  tags = merge(local.common_tags, { Vpc = "dr" })
}

module "dr_apps" {
  source = "../../modules/demo-service"

  services = {
    # A standby frontend that still depends on the payment service in the
    # primary Region -- and reaches it on a PRIVATE address, across Regions.
    frontend-dr = { port = local.frontend_port, upstream_url = "http://${module.app.private_ip}:${local.payment_port}/" }
  }
}

module "dr_host" {
  source = "../../modules/test-instance"

  providers = {
    aws = aws.dr
  }

  name          = "${local.name_prefix}-dr-web"
  vpc_id        = module.dr_vpc.vpc_id
  subnet_id     = module.dr_vpc.public_subnet_ids["public-a"]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  associate_public_ip_address = true

  user_data                   = module.dr_apps.user_data
  user_data_replace_on_change = true

  ingress_rules = {
    frontend = {
      description = "Standby shop frontend from the internet"
      ip_protocol = "tcp"
      from_port   = local.frontend_port
      to_port     = local.frontend_port
      cidr_ipv4   = var.allowed_client_cidr
    }
    icmp = {
      description = "ICMP echo request from any VPC in the project"
      ip_protocol = "icmp"
      from_port   = 8
      to_port     = -1
      cidr_ipv4   = var.supernet_cidr
    }
  }

  tags = merge(local.common_tags, { Vpc = "dr" })
}

# The payment service accepts the DR frontend. A security group cannot
# reference a group in another Region, so this is an address range.
resource "aws_vpc_security_group_ingress_rule" "app_from_dr" {
  security_group_id = module.app.security_group_id
  description       = "Payment service from the DR Region frontend"
  ip_protocol       = "tcp"
  from_port         = local.payment_port
  to_port           = local.payment_port
  cidr_ipv4         = var.dr_vpc_cidr
}

# -----------------------------------------------------------------------------
# Inter-Region VPC peering
#
# The same resource as lab 09 with one difference: it cannot accept itself.
# The request is made in one Region and accepted in the other.
# -----------------------------------------------------------------------------
resource "aws_vpc_peering_connection" "dr" {
  count = var.enable_inter_region_peering ? 1 : 0

  vpc_id      = module.vpc.vpc_id
  peer_vpc_id = module.dr_vpc.vpc_id
  peer_region = var.dr_region
  auto_accept = false

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-pcx-shop-dr" })
}

resource "aws_vpc_peering_connection_accepter" "dr" {
  count    = var.enable_inter_region_peering ? 1 : 0
  provider = aws.dr

  vpc_peering_connection_id = aws_vpc_peering_connection.dr[0].id
  auto_accept               = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-pcx-shop-dr" })
}

# The shop has three route tables; each needs the route. With the Transit
# Gateway on, they also hold 10.0.0.0/8 -> tgw. This /16 is more specific, so
# it wins: longest prefix match, not the order routes were added.
resource "aws_route" "shop_to_dr" {
  for_each = var.enable_inter_region_peering ? local.vpc_route_table_ids["shop"] : {}

  route_table_id            = each.value
  destination_cidr_block    = var.dr_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.dr[0].id
}

resource "aws_route" "dr_to_shop" {
  count    = var.enable_inter_region_peering ? 1 : 0
  provider = aws.dr

  route_table_id            = module.dr_vpc.public_route_table_id
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.dr[0].id

  depends_on = [aws_vpc_peering_connection_accepter.dr]
}

# -----------------------------------------------------------------------------
# Transit Gateway peering -- opt-in
#
# Peering attachments do not propagate routes. Every prefix that should cross
# is a static route, on both gateways.
# -----------------------------------------------------------------------------
resource "aws_ec2_transit_gateway" "dr" {
  count    = local.create_tgw_peering ? 1 : 0
  provider = aws.dr

  description = "${local.name_prefix} DR hub"

  # Different from the primary gateway's 64512. Not required for peering with
  # static routes, but identical ASNs rule out ever running BGP between them.
  amazon_side_asn = 64515

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-tgw-dr" })
}

resource "aws_ec2_transit_gateway_vpc_attachment" "dr" {
  count    = local.create_tgw_peering ? 1 : 0
  provider = aws.dr

  transit_gateway_id = aws_ec2_transit_gateway.dr[0].id
  vpc_id             = module.dr_vpc.vpc_id
  subnet_ids         = [module.dr_vpc.public_subnet_ids["public-a"]]

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-attach-dr" })
}

resource "aws_ec2_transit_gateway_peering_attachment" "dr" {
  count = local.create_tgw_peering ? 1 : 0

  transit_gateway_id      = aws_ec2_transit_gateway.this[0].id
  peer_transit_gateway_id = aws_ec2_transit_gateway.dr[0].id
  peer_region             = var.dr_region

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-tgw-peering-dr" })
}

resource "aws_ec2_transit_gateway_peering_attachment_accepter" "dr" {
  count    = local.create_tgw_peering ? 1 : 0
  provider = aws.dr

  transit_gateway_attachment_id = aws_ec2_transit_gateway_peering_attachment.dr[0].id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-tgw-peering-dr" })
}

# Traffic ARRIVING from the DR Region consults the shared table, which knows
# shop and dev.
resource "aws_ec2_transit_gateway_route_table_association" "dr_peering" {
  count = local.create_tgw_peering ? 1 : 0

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.dr[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.shared[0].id

  depends_on = [aws_ec2_transit_gateway_peering_attachment_accepter.dr]
}

# Traffic LEAVING for the DR Region: a static route in each primary table.
resource "aws_ec2_transit_gateway_route" "primary_to_dr" {
  for_each = local.create_tgw_peering ? {
    spoke  = aws_ec2_transit_gateway_route_table.spoke[0].id
    shared = aws_ec2_transit_gateway_route_table.shared[0].id
  } : {}

  destination_cidr_block         = var.dr_vpc_cidr
  transit_gateway_route_table_id = each.value
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.dr[0].id

  depends_on = [aws_ec2_transit_gateway_peering_attachment_accepter.dr]
}

# And on the DR gateway, a static route back for each primary VPC.
resource "aws_ec2_transit_gateway_route" "dr_to_primary" {
  for_each = local.create_tgw_peering ? local.vpc_cidrs : {}
  provider = aws.dr

  destination_cidr_block         = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway.dr[0].association_default_route_table_id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.dr[0].id

  depends_on = [aws_ec2_transit_gateway_peering_attachment_accepter.dr]
}

resource "aws_route" "dr_to_supernet_via_tgw" {
  count    = local.create_tgw_peering ? 1 : 0
  provider = aws.dr

  route_table_id         = module.dr_vpc.public_route_table_id
  destination_cidr_block = var.supernet_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.dr[0].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.dr]
}

# -----------------------------------------------------------------------------
# DNS failover -- opt-in
#
# Connecting two Regions does not send a single user to the second one. DNS
# does: Route 53 checks the primary endpoint from around the world and changes
# its ANSWER when the check fails.
# -----------------------------------------------------------------------------
resource "aws_route53_health_check" "primary" {
  count = var.enable_dns_failover ? 1 : 0

  type              = "HTTP"
  fqdn              = local.primary_endpoint_is_alb ? aws_lb.shop[0].dns_name : null
  ip_address        = local.primary_endpoint_is_alb ? null : module.web.public_ip
  port              = local.frontend_port
  resource_path     = "/"
  request_interval  = 30
  failure_threshold = 3

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-primary" })
}

resource "aws_route53_record" "failover_primary_alb" {
  count = var.enable_dns_failover && local.primary_endpoint_is_alb ? 1 : 0

  zone_id        = data.aws_route53_zone.public[0].zone_id
  name           = "global.${var.shop_record_name}.${var.public_zone_name}"
  type           = "A"
  set_identifier = "primary"

  health_check_id = aws_route53_health_check.primary[0].id

  failover_routing_policy {
    type = "PRIMARY"
  }

  alias {
    name                   = aws_lb.shop[0].dns_name
    zone_id                = aws_lb.shop[0].zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "failover_primary_host" {
  count = var.enable_dns_failover && !local.primary_endpoint_is_alb ? 1 : 0

  zone_id        = data.aws_route53_zone.public[0].zone_id
  name           = "global.${var.shop_record_name}.${var.public_zone_name}"
  type           = "A"
  ttl            = 30
  set_identifier = "primary"
  records        = [module.web.public_ip]

  health_check_id = aws_route53_health_check.primary[0].id

  failover_routing_policy {
    type = "PRIMARY"
  }
}

# Returned only while the primary is unhealthy. The short TTL bounds how long
# clients keep using a stale answer.
resource "aws_route53_record" "failover_secondary" {
  count = var.enable_dns_failover ? 1 : 0

  zone_id        = data.aws_route53_zone.public[0].zone_id
  name           = "global.${var.shop_record_name}.${var.public_zone_name}"
  type           = "A"
  ttl            = 30
  set_identifier = "dr"
  records        = [module.dr_host.public_ip]

  failover_routing_policy {
    type = "SECONDARY"
  }
}

output "dr_host_private_ip" {
  description = "Private address of the standby frontend in the DR Region."
  value       = module.dr_host.private_ip
}

output "dr_frontend_url" {
  description = "The standby frontend in the DR Region. Its answer embeds the payment service's, fetched across Regions on private addresses."
  value       = "http://${module.dr_host.public_ip}/"
}

output "ssm_dr_host" {
  description = "Open a shell on the DR host. Note the --region."
  value       = module.dr_host.ssm_start_session_command
}

output "verify_multi_region" {
  description = "Commands for checking inter-Region networking. The from_* commands run in a shell on the named host."
  value = merge(
    {
      dr_frontend_reaches_primary_payment = "curl -s http://${module.dr_host.public_ip}/"

      peering_status = "aws ec2 describe-vpc-peering-connections --filters Name=tag:Name,Values=${local.name_prefix}-pcx-shop-dr --region ${var.aws_region} --query 'VpcPeeringConnections[].{Status:Status.Code,Requester:RequesterVpcInfo.Region,Accepter:AccepterVpcInfo.Region}' --output table"

      from_web_ping_dr_latency = "ping -c 5 ${module.dr_host.private_ip}"
      from_web_route_to_dr     = "aws ec2 describe-route-tables --route-table-ids ${module.vpc.public_route_table_id} --region ${var.aws_region} --query 'RouteTables[0].Routes[].{Dest:DestinationCidrBlock,Peering:VpcPeeringConnectionId,Tgw:TransitGatewayId,Gw:GatewayId}' --output table"
    },
    var.enable_dns_failover ? {
      failover_answer     = "dig +short global.${var.shop_record_name}.${var.public_zone_name}"
      health_check_status = "aws route53 get-health-check-status --health-check-id ${aws_route53_health_check.primary[0].id} --query 'HealthCheckObservations[].{Region:Region,Status:StatusReport.Status}' --output table"
    } : {},
  )
}
