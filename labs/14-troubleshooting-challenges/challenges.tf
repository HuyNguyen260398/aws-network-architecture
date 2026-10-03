# =============================================================================
# Troubleshooting challenges.
#
# The network is finished. This file breaks it, on request.
#
# Each challenge injects ONE fault into the project you have built over the
# previous thirteen labs. Nothing errors, `terraform apply` succeeds, and
# something stops working. Your job is to find out what, using only the tools
# from lab 08 and the read-only commands in the earlier labs.
#
# DO NOT READ PAST THE VARIABLE BLOCK if you want the challenges to be
# challenges. The faults are written out below it in plain Terraform.
# Read the brief with `terraform output challenge_briefs`, investigate, then
# check HINTS.md, and only then SOLUTIONS.md.
# =============================================================================

variable "challenges" {
  description = <<-EOT
    Which faults to inject. An empty list leaves the network working.

      missing-route         a partner VPC is peered with the shop and cannot be reached
      security-group        a partner VPC is peered and routed, and still cannot be reached
      nacl-ephemeral        the payment service can no longer use the database
      wrong-next-hop        the web server can no longer reach the payment service
      broken-dns            a name in shop.internal resolves, and the connection fails
      listener-rule-order   /pay returns the wrong service (needs enable_load_balancer)

    Enable one at a time.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for c in var.challenges : contains(
        ["missing-route", "security-group", "nacl-ephemeral", "wrong-next-hop", "broken-dns", "listener-rule-order"], c
      )
    ])
    error_message = "Unknown challenge. Valid values: missing-route, security-group, nacl-ephemeral, wrong-next-hop, broken-dns, listener-rule-order."
  }

  validation {
    condition     = !contains(var.challenges, "listener-rule-order") || var.enable_load_balancer
    error_message = "The listener-rule-order challenge needs enable_load_balancer = true (and acknowledge_costs = true)."
  }

  validation {
    condition     = !contains(var.challenges, "wrong-next-hop") || !var.enable_network_firewall
    error_message = "The wrong-next-hop challenge cannot be combined with enable_network_firewall: both add a route for the same destination."
  }
}

variable "partner_vpc_cidr" {
  description = "IPv4 range of the partner VPC that two of the challenges create."
  type        = string
  default     = "10.40.0.0/16"

  validation {
    condition     = can(cidrhost(var.partner_vpc_cidr, 0)) && can(regex("^.*/16$", var.partner_vpc_cidr))
    error_message = "partner_vpc_cidr must be a valid /16."
  }
}

# =============================================================================
#
#                               S P O I L E R S
#
#                 Everything below this line is the answer key.
#
# =============================================================================

locals {
  c = {
    missing_route       = contains(var.challenges, "missing-route")
    security_group      = contains(var.challenges, "security-group")
    nacl_ephemeral      = contains(var.challenges, "nacl-ephemeral")
    wrong_next_hop      = contains(var.challenges, "wrong-next-hop")
    broken_dns          = contains(var.challenges, "broken-dns")
    listener_rule_order = contains(var.challenges, "listener-rule-order") && local.load_balancer_enabled
  }

  need_partner_vpc = local.c.missing_route || local.c.security_group

  # What the learner is told. Symptoms only.
  briefs = {
    "missing-route"       = "A partner company's VPC (${var.partner_vpc_cidr}) has been peered with the shop. The peering connection is active. From the web server, `curl --max-time 5 http://partner.${var.private_zone_name}:${local.tools_port}/` times out. Make it work."
    "security-group"      = "A partner company's VPC (${var.partner_vpc_cidr}) has been peered with the shop, and both sides have routes. From the web server, `curl --max-time 5 http://partner.${var.private_zone_name}:${local.tools_port}/` times out, yet `ping partner.${var.private_zone_name}` works. Make the curl work."
    "nacl-ephemeral"      = "The shop is up, but every response now contains an upstream_error from the payment service: it can no longer use the database. Nobody changed a security group or a route. Find what changed."
    "wrong-next-hop"      = "The shop is up, but the frontend reports an upstream_error: it cannot reach the payment service. The app host is running, its security group is unchanged, and the route tables still have their local route. Find where the packets are going."
    "broken-dns"          = "From the web server, `curl --max-time 5 http://app.${var.private_zone_name}:${local.payment_port}/` fails, but `curl http://<app private IP>:${local.payment_port}/` works. From the dev host the name resolves correctly. Find out why the answers differ."
    "listener-rule-order" = "Through the load balancer, `/pay/checkout` used to be answered by the payment service. It is now answered by the frontend. The payment target group is healthy. Find out why."
  }
}

# -----------------------------------------------------------------------------
# The partner VPC (missing-route, security-group)
# -----------------------------------------------------------------------------
module "partner_vpc" {
  count  = local.need_partner_vpc ? 1 : 0
  source = "../../modules/vpc"

  name       = "${local.name_prefix}-partner"
  cidr_block = var.partner_vpc_cidr

  public_subnets = {
    "public-a" = {
      cidr_block              = cidrsubnet(var.partner_vpc_cidr, 8, 0)
      az_index                = 0
      map_public_ip_on_launch = true
    }
  }
  create_internet_gateway = true

  tags = merge(local.common_tags, { Vpc = "partner" })
}

module "partner_apps" {
  source = "../../modules/demo-service"

  services = {
    partner = { port = local.tools_port }
  }
}

module "partner_host" {
  count  = local.need_partner_vpc ? 1 : 0
  source = "../../modules/test-instance"

  name          = "${local.name_prefix}-partner"
  vpc_id        = module.partner_vpc[0].vpc_id
  subnet_id     = module.partner_vpc[0].public_subnet_ids["public-a"]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  associate_public_ip_address = true

  user_data                   = module.partner_apps.user_data
  user_data_replace_on_change = true

  ingress_rules = {
    service = {
      description = "Partner service from the shop VPC"
      ip_protocol = "tcp"
      from_port   = local.tools_port
      to_port     = local.tools_port
      # FAULT (security-group): one digit off. 10.11.0.0/16 is not the shop.
      # Ping still works because the ICMP rule below uses the right range.
      cidr_ipv4 = local.c.security_group ? cidrsubnet(var.supernet_cidr, 8, 11) : var.vpc_cidr
    }
    icmp = {
      description = "ICMP echo request from the shop VPC"
      ip_protocol = "icmp"
      from_port   = 8
      to_port     = -1
      cidr_ipv4   = var.vpc_cidr
    }
  }

  tags = merge(local.common_tags, { Vpc = "partner" })
}

resource "aws_vpc_peering_connection" "partner" {
  count = local.need_partner_vpc ? 1 : 0

  vpc_id      = module.vpc.vpc_id
  peer_vpc_id = module.partner_vpc[0].vpc_id
  auto_accept = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-pcx-shop-partner" })
}

resource "aws_route" "shop_to_partner" {
  for_each = local.need_partner_vpc ? local.vpc_route_table_ids["shop"] : {}

  route_table_id            = each.value
  destination_cidr_block    = var.partner_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.partner[0].id
}

# FAULT (missing-route): this return route is simply not created. The request
# arrives at the partner host; the reply has no way back.
resource "aws_route" "partner_to_shop" {
  count = local.need_partner_vpc && !local.c.missing_route ? 1 : 0

  route_table_id            = module.partner_vpc[0].public_route_table_id
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.partner[0].id
}

resource "aws_route53_record" "partner" {
  count = local.need_partner_vpc ? 1 : 0

  zone_id = aws_route53_zone.private.zone_id
  name    = "partner.${var.private_zone_name}"
  type    = "A"
  ttl     = 60
  records = [module.partner_host[0].private_ip]
}

# -----------------------------------------------------------------------------
# FAULT (nacl-ephemeral)
#
# Lab 08's fault blocked the request. This one lets the request in and drops
# the REPLY: an outbound deny on the ephemeral port range, numbered below the
# allow. Flow logs show ACCEPT inbound and REJECT outbound on the same flow.
# -----------------------------------------------------------------------------
resource "aws_network_acl_rule" "challenge_data_out_deny_ephemeral" {
  count = local.c.nacl_ephemeral ? 1 : 0

  network_acl_id = aws_network_acl.data.id
  rule_number    = 90
  egress         = true
  protocol       = "tcp"
  rule_action    = "deny"
  cidr_block     = var.vpc_cidr
  from_port      = 1024
  to_port        = 65535
}

# -----------------------------------------------------------------------------
# FAULT (wrong-next-hop)
#
# A route MORE SPECIFIC than the VPC's local route, sending web -> app traffic
# to the database host's network interface. The database host is not a router
# and has source/destination checking on, so it discards the packets. The
# local route is still there; it just no longer wins.
# -----------------------------------------------------------------------------
resource "aws_route" "challenge_wrong_next_hop" {
  count = local.c.wrong_next_hop ? 1 : 0

  route_table_id         = module.vpc.public_route_table_id
  destination_cidr_block = local.app_subnets["app-a"].cidr_block
  network_interface_id   = module.db.primary_network_interface_id
}

# -----------------------------------------------------------------------------
# FAULT (broken-dns)
#
# A second private zone named exactly app.shop.internal, associated with the
# shop VPC only. When two private zones could answer, the most specific zone
# name wins -- so inside the shop VPC this zone shadows the record in
# shop.internal. Dev is not associated with it and still gets the right answer.
# -----------------------------------------------------------------------------
resource "aws_route53_zone" "challenge_shadow" {
  count = local.c.broken_dns ? 1 : 0

  name    = "app.${var.private_zone_name}"
  comment = "${local.name_prefix} staging override"

  vpc {
    vpc_id     = module.vpc.vpc_id
    vpc_region = var.aws_region
  }

  tags = merge(local.common_tags, { Name = "app.${var.private_zone_name}" })
}

resource "aws_route53_record" "challenge_shadow" {
  count = local.c.broken_dns ? 1 : 0

  zone_id = aws_route53_zone.challenge_shadow[0].zone_id
  name    = "app.${var.private_zone_name}"
  type    = "A"
  ttl     = 60
  # An unused address in the app subnet: plausible, and nothing answers.
  records = [cidrhost(local.app_subnets["app-a"].cidr_block, 250)]
}

# -----------------------------------------------------------------------------
# FAULT (listener-rule-order)
#
# A broader rule with a LOWER priority number than the payment rule. Rules are
# evaluated lowest number first and the first match wins, so /pay/* never
# reaches the rule written for it.
# -----------------------------------------------------------------------------
resource "aws_lb_listener_rule" "challenge_catch_all" {
  count = local.c.listener_rule_order ? 1 : 0

  listener_arn = aws_lb_listener.http[0].arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.instance["frontend"].arn
  }

  condition {
    path_pattern {
      values = ["/p*"]
    }
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-promotions" })
}

check "one_challenge_at_a_time" {
  assert {
    condition     = length(var.challenges) <= 1
    error_message = "More than one challenge is enabled. Interacting faults are realistic but they are a poor way to learn: enable one, diagnose it, clear the list, repeat."
  }
}

output "challenge_briefs" {
  description = "The symptom of each enabled challenge. This is all you are told."
  value       = { for c in var.challenges : c => local.briefs[c] }
}
