# =============================================================================
# Private DNS.
#
# Every address used so far inside the project was an IP copied from an
# output. Hosts get replaced and addresses change; names should not.
#
# A PRIVATE hosted zone is a DNS zone that exists only for the VPCs it is
# associated with. Each VPC's built-in resolver (at the VPC range's base
# address plus two) answers from it; nothing outside those VPCs can see it.
# =============================================================================

variable "private_zone_name" {
  description = "Name of the private hosted zone for the project. Must not be a domain that exists on the internet unless you intend to override it."
  type        = string
  default     = "shop.internal"
}

variable "split_horizon_domain" {
  description = "Optional: a PUBLIC domain to answer differently inside the project's VPCs, for example example.com. A second private zone is created for it, and inside the VPCs its apex resolves to the web server's private address while the rest of the world still gets the public answer. Null skips it."
  type        = string
  default     = null
}

variable "enable_resolver_inbound_endpoint" {
  description = <<-EOT
    Create a Route 53 Resolver INBOUND endpoint: addresses in the shop VPC that
    networks outside AWS can send DNS queries to, so the office (lab 12) can
    resolve shop.internal names.

    COST: USD 0.125 per ENI-hour and two ENIs are mandatory, so USD 0.25/hour
    -- USD 180/month.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_resolver_inbound_endpoint || var.acknowledge_costs
    error_message = "enable_resolver_inbound_endpoint requires acknowledge_costs = true. A Resolver endpoint costs about USD 180/month."
  }
}

variable "enable_resolver_outbound_endpoint" {
  description = <<-EOT
    Create a Route 53 Resolver OUTBOUND endpoint and a forwarding rule: queries
    for forward_domain leave the VPC for the DNS servers in forward_target_ips,
    so AWS hosts can resolve names that live on-premises.

    COST: USD 0.25/hour -- USD 180/month -- as for the inbound endpoint.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_resolver_outbound_endpoint || var.acknowledge_costs
    error_message = "enable_resolver_outbound_endpoint requires acknowledge_costs = true. A Resolver endpoint costs about USD 180/month."
  }
}

variable "forward_domain" {
  description = "Domain whose queries the outbound endpoint forwards."
  type        = string
  default     = "office.example"
}

variable "forward_target_ips" {
  description = "DNS servers the forwarding rule sends forward_domain queries to. The defaults are documentation addresses: the rule is real, the servers are not."
  type        = list(string)
  default     = ["192.0.2.53"]

  validation {
    condition     = length(var.forward_target_ips) > 0 && alltrue([for ip in var.forward_target_ips : can(cidrhost("${ip}/32", 0))])
    error_message = "forward_target_ips must be a non-empty list of IPv4 addresses."
  }
}

locals {
  create_resolver_inbound  = var.enable_resolver_inbound_endpoint && var.acknowledge_costs
  create_resolver_outbound = var.enable_resolver_outbound_endpoint && var.acknowledge_costs
  create_resolver_any      = local.create_resolver_inbound || local.create_resolver_outbound

  private_records = {
    web   = module.web.private_ip
    app   = module.app.private_ip
    db    = module.db.private_ip
    tools = module.other_host["shared"].private_ip
    dev   = module.other_host["dev"].private_ip
  }

  resolver_subnet_ids = [for key in sort(keys(local.app_subnets)) : module.vpc.private_subnet_ids[key]]
}

# One zone, associated with all three VPCs. Association is what makes a VPC's
# resolver answer from the zone -- it has nothing to do with whether the VPCs
# can route to each other.
resource "aws_route53_zone" "private" {
  name    = var.private_zone_name
  comment = "${local.name_prefix} private zone"

  dynamic "vpc" {
    for_each = local.vpc_ids

    content {
      vpc_id     = vpc.value
      vpc_region = var.aws_region
    }
  }

  tags = merge(local.common_tags, { Name = var.private_zone_name })
}

resource "aws_route53_record" "private" {
  for_each = local.private_records

  zone_id = aws_route53_zone.private.zone_id
  name    = "${each.key}.${var.private_zone_name}"
  type    = "A"
  ttl     = 60
  records = [each.value]
}

# Split horizon: the same name, two answers, depending on where you ask from.
resource "aws_route53_zone" "split_horizon" {
  count = var.split_horizon_domain == null ? 0 : 1

  name    = var.split_horizon_domain
  comment = "${local.name_prefix} split-horizon demonstration -- overrides the public answer inside these VPCs only"

  dynamic "vpc" {
    for_each = local.vpc_ids

    content {
      vpc_id     = vpc.value
      vpc_region = var.aws_region
    }
  }

  tags = merge(local.common_tags, { Name = "${var.split_horizon_domain}-private" })
}

resource "aws_route53_record" "split_horizon_apex" {
  count = var.split_horizon_domain == null ? 0 : 1

  zone_id = aws_route53_zone.split_horizon[0].zone_id
  name    = var.split_horizon_domain
  type    = "A"
  ttl     = 60
  records = [module.web.private_ip]
}

# -----------------------------------------------------------------------------
# Route 53 Resolver endpoints -- opt-in, USD 0.25/hour EACH
#
# The VPC resolver only answers queries that come from inside its VPC, and
# only knows AWS-side names. Endpoints are the two doors through that wall.
# -----------------------------------------------------------------------------
resource "aws_security_group" "resolver" {
  count = local.create_resolver_any ? 1 : 0

  name_prefix = "${local.name_prefix}-resolver-"
  description = "DNS on TCP and UDP 53 for the Route 53 Resolver endpoints"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-resolver" })

  lifecycle {
    create_before_destroy = true
  }
}

# DNS uses UDP for ordinary queries and TCP for answers too large for one
# datagram. Allowing only UDP works until the day it does not.
resource "aws_vpc_security_group_ingress_rule" "resolver" {
  for_each = local.create_resolver_any ? toset(["udp", "tcp"]) : toset([])

  security_group_id = aws_security_group.resolver[0].id
  description       = "DNS over ${upper(each.value)} from any VPC in the project"
  ip_protocol       = each.value
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = var.supernet_cidr
}

resource "aws_vpc_security_group_egress_rule" "resolver_all" {
  count = local.create_resolver_any ? 1 : 0

  security_group_id = aws_security_group.resolver[0].id
  description       = "All outbound, so the outbound endpoint can reach forwarding targets"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_route53_resolver_endpoint" "inbound" {
  count = local.create_resolver_inbound ? 1 : 0

  name                   = "${local.name_prefix}-inbound"
  direction              = "INBOUND"
  security_group_ids     = [aws_security_group.resolver[0].id]
  resolver_endpoint_type = "IPV4"

  # Two addresses in two zones are the minimum AWS accepts.
  dynamic "ip_address" {
    for_each = local.resolver_subnet_ids

    content {
      subnet_id = ip_address.value
    }
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-inbound-resolver" })
}

resource "aws_route53_resolver_endpoint" "outbound" {
  count = local.create_resolver_outbound ? 1 : 0

  name                   = "${local.name_prefix}-outbound"
  direction              = "OUTBOUND"
  security_group_ids     = [aws_security_group.resolver[0].id]
  resolver_endpoint_type = "IPV4"

  dynamic "ip_address" {
    for_each = local.resolver_subnet_ids

    content {
      subnet_id = ip_address.value
    }
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-outbound-resolver" })
}

resource "aws_route53_resolver_rule" "forward" {
  count = local.create_resolver_outbound ? 1 : 0

  name                 = replace("${local.name_prefix}-forward", "-", "_")
  domain_name          = var.forward_domain
  rule_type            = "FORWARD"
  resolver_endpoint_id = aws_route53_resolver_endpoint.outbound[0].id

  dynamic "target_ip" {
    for_each = var.forward_target_ips

    content {
      ip = target_ip.value
    }
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-forward-rule" })
}

# A rule does nothing until it is associated with a VPC.
resource "aws_route53_resolver_rule_association" "forward" {
  count = local.create_resolver_outbound ? 1 : 0

  resolver_rule_id = aws_route53_resolver_rule.forward[0].id
  vpc_id           = module.vpc.vpc_id
}

output "private_zone_id" {
  description = "ID of the project's private hosted zone."
  value       = aws_route53_zone.private.zone_id
}

output "private_dns_names" {
  description = "Names in the private zone and the addresses they resolve to."
  value       = { for name, ip in local.private_records : "${name}.${var.private_zone_name}" => ip }
}

output "resolver_inbound_ip_addresses" {
  description = "Addresses an on-premises DNS server forwards shop.internal queries to. Empty unless the inbound endpoint is enabled."
  value       = local.create_resolver_inbound ? [for ip in aws_route53_resolver_endpoint.inbound[0].ip_address : ip.ip] : []
}

output "verify_private_dns" {
  description = "Commands for checking private DNS. The from_* commands run in a shell on the named host."
  value = {
    zone_associations = "aws route53 get-hosted-zone --id ${aws_route53_zone.private.zone_id} --query 'VPCs' --output table"

    from_web_resolve_app      = "dig +short app.${var.private_zone_name}"
    from_web_which_resolver   = "cat /etc/resolv.conf"
    from_web_call_by_name     = "curl -s http://app.${var.private_zone_name}:${local.payment_port}/"
    from_dev_resolve_app      = "dig +short app.${var.private_zone_name}"
    from_dev_but_cannot_reach = "curl -s --max-time 5 http://app.${var.private_zone_name}:${local.payment_port}/ || echo 'resolved, then timed out: DNS is not connectivity'"

    from_your_machine_no_answer = "dig +short app.${var.private_zone_name}"
  }
}
