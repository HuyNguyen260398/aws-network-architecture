# =============================================================================
# Lab 06 -- DNS and private service connectivity
#
# Two ideas that are usually taught separately and belong together, because in
# practice a PrivateLink problem is almost always a DNS problem:
#
#   Route 53 private hosted zones -- names that resolve differently, or only,
#   inside a VPC. Including split-horizon, where the same name gives a different
#   answer inside than out.
#
#   AWS PrivateLink -- consuming a service in another VPC (usually another
#   account) WITHOUT joining the two networks. No routes are exchanged, so the
#   two VPCs may have identical CIDRs and it still works.
#
# COSTS
#   Private hosted zone            USD 0.50/month each, regardless of queries
#   PrivateLink (opt-in)           ~USD 0.045/hour  (NLB + endpoint ENI)
#   Resolver endpoint (opt-in)     USD 0.25/hour EACH -- two mandatory ENIs
# =============================================================================

module "vpc" {
  source   = "../../modules/vpc"
  for_each = local.vpcs

  name       = "${local.name_prefix}-${each.key}"
  cidr_block = each.value

  public_subnets          = local.subnets[each.key]
  create_internet_gateway = true
  nat_gateway_mode        = "none"

  tags = merge(local.common_tags, { Role = each.key })
}

# =============================================================================
# Route 53 private hosted zones -- USD 0.50/month each
# =============================================================================

# A private hosted zone resolves ONLY from the VPCs it is associated with.
# Associating it with both VPCs is what lets the consumer resolve names that
# describe resources in the provider VPC -- which is a different thing from
# being able to reach them.
resource "aws_route53_zone" "private" {
  name    = var.private_zone_name
  comment = "${local.name_prefix} private zone"

  dynamic "vpc" {
    for_each = module.vpc

    content {
      vpc_id     = vpc.value.vpc_id
      vpc_region = var.aws_region
    }
  }

  tags = merge(local.common_tags, { Name = var.private_zone_name })
}

resource "aws_route53_record" "consumer_host" {
  count = var.enable_test_instances ? 1 : 0

  zone_id = aws_route53_zone.private.zone_id
  name    = "consumer.${var.private_zone_name}"
  type    = "A"
  ttl     = 60
  records = [module.consumer_instance[0].private_ip]
}

resource "aws_route53_record" "provider_host" {
  count = local.create_provider_instance ? 1 : 0

  zone_id = aws_route53_zone.private.zone_id
  name    = "app.${var.private_zone_name}"
  type    = "A"
  ttl     = 60
  records = [module.provider_instance[0].private_ip]
}

# -----------------------------------------------------------------------------
# Split-horizon DNS
#
# A private hosted zone for a name that ALSO exists publicly. Inside the
# associated VPCs, Route 53 answers authoritatively and the public answer is
# never consulted; outside, nothing changes.
#
# This is how organisations point api.example.com at an internal load balancer
# for internal clients and at a public one for everyone else. It is also how
# people accidentally black-hole a third-party service for their whole VPC, by
# creating a private zone for a domain they do not fully control.
#
# The default is example.com, reserved for documentation by RFC 2606.
# -----------------------------------------------------------------------------
resource "aws_route53_zone" "split_horizon" {
  count = var.split_horizon_domain == null ? 0 : 1

  name    = var.split_horizon_domain
  comment = "${local.name_prefix} split-horizon demonstration -- overrides the public answer inside these VPCs only"

  dynamic "vpc" {
    for_each = module.vpc

    content {
      vpc_id     = vpc.value.vpc_id
      vpc_region = var.aws_region
    }
  }

  tags = merge(local.common_tags, { Name = "${var.split_horizon_domain}-private" })
}

resource "aws_route53_record" "split_horizon_apex" {
  count = var.split_horizon_domain != null && var.enable_test_instances ? 1 : 0

  zone_id = aws_route53_zone.split_horizon[0].zone_id
  name    = var.split_horizon_domain
  type    = "A"
  ttl     = 60
  records = [module.consumer_instance[0].private_ip]
}

# =============================================================================
# AWS PrivateLink -- opt-in
#
# The provider publishes a service behind a Network Load Balancer. The consumer
# creates an interface endpoint pointing at it. No peering, no Transit Gateway,
# no routes, and the two VPCs may use identical CIDRs.
# =============================================================================
resource "aws_lb" "provider" {
  count = local.create_privatelink ? 1 : 0

  name               = substr("${local.name_prefix}-nlb", 0, 32)
  load_balancer_type = "network"

  # Internal, not internet-facing. A PrivateLink endpoint service publishes to
  # other VPCs, not to the internet -- an internet-facing NLB here would be a
  # security mistake, not just an unnecessary one.
  internal = true
  subnets  = module.vpc["provider"].public_subnet_ids_list

  enable_deletion_protection       = false
  enable_cross_zone_load_balancing = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-nlb" })
}

resource "aws_lb_target_group" "provider" {
  count = local.create_privatelink ? 1 : 0

  name        = substr("${local.name_prefix}-tg", 0, 32)
  port        = 8080
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = module.vpc["provider"].vpc_id

  health_check {
    protocol            = "TCP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-tg" })
}

resource "aws_lb_target_group_attachment" "provider" {
  count = local.create_provider_instance ? 1 : 0

  target_group_arn = aws_lb_target_group.provider[0].arn
  target_id        = module.provider_instance[0].instance_id
  port             = 8080
}

resource "aws_lb_listener" "provider" {
  count = local.create_privatelink ? 1 : 0

  load_balancer_arn = aws_lb.provider[0].arn
  port              = 8080
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.provider[0].arn
  }
}

# The endpoint service is what makes the NLB consumable from other VPCs and
# other accounts.
resource "aws_vpc_endpoint_service" "provider" {
  count = local.create_privatelink ? 1 : 0

  network_load_balancer_arns = [aws_lb.provider[0].arn]

  # In production leave this false, so every consumer connection needs an
  # explicit approval. It is true here so the lab's own endpoint connects
  # without a manual step -- and because the allowed-principals list below is
  # what actually restricts who may connect.
  acceptance_required = false

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-endpoint-service" })
}

data "aws_caller_identity" "current" {}

# Who may create an endpoint to this service. Without this, any AWS account
# that learns the service name could connect (subject to acceptance). Scoping
# it to this account is the least-privilege default; a real service would list
# specific consumer account ARNs or an Organizations principal.
resource "aws_vpc_endpoint_service_allowed_principal" "this_account" {
  count = local.create_privatelink ? 1 : 0

  vpc_endpoint_service_id = aws_vpc_endpoint_service.provider[0].id
  principal_arn           = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
}

# The consumer side: an ENI in the consumer VPC that forwards to the provider's
# NLB. This is the only thing the consumer VPC knows about the provider -- no
# route, no CIDR, no visibility into the provider's network.
resource "aws_security_group" "consumer_endpoint" {
  count = local.create_privatelink ? 1 : 0

  name_prefix = "${local.name_prefix}-vpce-"
  description = "Consumer-side access to the PrivateLink endpoint on TCP 8080"
  vpc_id      = module.vpc["consumer"].vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-vpce-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "consumer_endpoint" {
  count = local.create_privatelink ? 1 : 0

  security_group_id = aws_security_group.consumer_endpoint[0].id
  description       = "Service port from within the consumer VPC"
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
  cidr_ipv4         = var.consumer_vpc_cidr

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-vpce-ingress" })
}

resource "aws_vpc_endpoint" "consumer" {
  count = local.create_privatelink ? 1 : 0

  vpc_id            = module.vpc["consumer"].vpc_id
  service_name      = aws_vpc_endpoint_service.provider[0].service_name
  vpc_endpoint_type = "Interface"

  subnet_ids         = module.vpc["consumer"].public_subnet_ids_list
  security_group_ids = [aws_security_group.consumer_endpoint[0].id]

  # Private DNS is not available for a customer-published endpoint service
  # unless the provider has verified ownership of a domain. Without it, the
  # consumer uses the endpoint's generated DNS name -- which is exactly why the
  # private hosted zone below exists.
  private_dns_enabled = false

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-consumer-vpce" })
}

# The friendly name. Consumers should not have to use
# vpce-0abc123-xyz.vpce-svc-0def.ap-southeast-1.vpce.amazonaws.com, so an alias
# in the private zone points at the endpoint. This is the standard pattern for
# making a PrivateLink service usable, and the reason DNS and PrivateLink are
# one lab rather than two.
resource "aws_route53_record" "privatelink_alias" {
  count = local.create_privatelink ? 1 : 0

  zone_id = aws_route53_zone.private.zone_id
  name    = "service.${var.private_zone_name}"
  type    = "CNAME"
  ttl     = 60
  records = [aws_vpc_endpoint.consumer[0].dns_entry[0].dns_name]
}

# =============================================================================
# Route 53 Resolver endpoints -- opt-in, USD 0.25/hour EACH
# =============================================================================
resource "aws_security_group" "resolver" {
  count = local.create_resolver_inbound || local.create_resolver_outbound ? 1 : 0

  name_prefix = "${local.name_prefix}-resolver-"
  description = "DNS on TCP and UDP 53 for the Route 53 Resolver endpoints"
  vpc_id      = module.vpc["consumer"].vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-resolver-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# DNS uses UDP for most queries and falls back to TCP for responses over 512
# bytes (and always for zone transfers). Allowing only UDP is a classic
# intermittent-DNS-failure cause: small answers work, large ones do not.
resource "aws_vpc_security_group_ingress_rule" "resolver_udp" {
  count = local.create_resolver_inbound || local.create_resolver_outbound ? 1 : 0

  security_group_id = aws_security_group.resolver[0].id
  description       = "DNS over UDP"
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = var.consumer_vpc_cidr

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-resolver-udp" })
}

resource "aws_vpc_security_group_ingress_rule" "resolver_tcp" {
  count = local.create_resolver_inbound || local.create_resolver_outbound ? 1 : 0

  security_group_id = aws_security_group.resolver[0].id
  description       = "DNS over TCP, needed for responses larger than 512 bytes"
  ip_protocol       = "tcp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = var.consumer_vpc_cidr

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-resolver-tcp" })
}

resource "aws_vpc_security_group_egress_rule" "resolver_all" {
  count = local.create_resolver_inbound || local.create_resolver_outbound ? 1 : 0

  security_group_id = aws_security_group.resolver[0].id
  description       = "All outbound, so the outbound endpoint can reach forwarding targets"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-resolver-egress" })
}

# INBOUND: lets DNS queries from OUTSIDE the VPC resolve names inside it.
# In production the queries come from on-premises over VPN or Direct Connect.
# AWS requires at least two ENIs in different Availability Zones.
resource "aws_route53_resolver_endpoint" "inbound" {
  count = local.create_resolver_inbound ? 1 : 0

  name                   = "${local.name_prefix}-inbound"
  direction              = "INBOUND"
  security_group_ids     = [aws_security_group.resolver[0].id]
  resolver_endpoint_type = "IPV4"

  dynamic "ip_address" {
    for_each = module.vpc["consumer"].public_subnet_ids_list

    content {
      subnet_id = ip_address.value
    }
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-inbound-resolver" })
}

# OUTBOUND: sends queries for specific domains to DNS servers you nominate,
# instead of letting AWS answer them.
resource "aws_route53_resolver_endpoint" "outbound" {
  count = local.create_resolver_outbound ? 1 : 0

  name                   = "${local.name_prefix}-outbound"
  direction              = "OUTBOUND"
  security_group_ids     = [aws_security_group.resolver[0].id]
  resolver_endpoint_type = "IPV4"

  dynamic "ip_address" {
    for_each = module.vpc["consumer"].public_subnet_ids_list

    content {
      subnet_id = ip_address.value
    }
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-outbound-resolver" })
}

# The rule is what actually redirects queries. Creating the endpoint alone
# changes nothing -- another case where the expensive resource and the resource
# that does the work are separate.
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

# A rule does nothing until it is associated with a VPC. Same pattern as a
# gateway endpoint and its route tables.
resource "aws_route53_resolver_rule_association" "forward" {
  count = local.create_resolver_outbound ? 1 : 0

  resolver_rule_id = aws_route53_resolver_rule.forward[0].id
  vpc_id           = module.vpc["consumer"].vpc_id
}

# =============================================================================
# Test instances
# =============================================================================
module "consumer_instance" {
  count  = var.enable_test_instances ? 1 : 0
  source = "../../modules/test-instance"

  name          = "${local.name_prefix}-consumer"
  vpc_id        = module.vpc["consumer"].vpc_id
  subnet_id     = module.vpc["consumer"].public_subnet_ids["public-a"]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  associate_public_ip_address = true

  tags = merge(local.common_tags, { Role = "consumer" })
}

module "provider_instance" {
  count  = local.create_provider_instance ? 1 : 0
  source = "../../modules/test-instance"

  name          = "${local.name_prefix}-provider"
  vpc_id        = module.vpc["provider"].vpc_id
  subnet_id     = module.vpc["provider"].public_subnet_ids["public-a"]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  associate_public_ip_address = true
  user_data                   = local.provider_user_data

  # The Network Load Balancer health-checks and forwards from within the
  # provider VPC. An NLB has no security group of its own, so the target's
  # security group must permit the VPC CIDR rather than a source group.
  ingress_rules = {
    service_from_vpc = {
      description = "Service port from the Network Load Balancer in this VPC"
      ip_protocol = "tcp"
      from_port   = 8080
      to_port     = 8080
      cidr_ipv4   = var.provider_vpc_cidr
    }
  }

  tags = merge(local.common_tags, { Role = "provider" })
}
