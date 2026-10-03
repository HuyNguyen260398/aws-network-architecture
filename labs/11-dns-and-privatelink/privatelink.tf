# =============================================================================
# PrivateLink: one service, not a whole network.
#
# Dev needs to call the payment service. Lab 10 deliberately gave dev no route
# to the shop, and opening one would expose every host in production to every
# host in dev.
#
# PrivateLink exposes exactly ONE listener of ONE service. The provider puts
# a Network Load Balancer in front of the service and publishes it as an
# endpoint service. The consumer creates an interface endpoint -- a network
# interface with an address in the CONSUMER's own VPC. No routes are
# exchanged, connections can only be opened from consumer to provider, and
# the two VPCs' address ranges could even overlap.
# =============================================================================

variable "enable_privatelink" {
  description = <<-EOT
    Publish the payment service as a PrivateLink endpoint service and consume
    it from the dev VPC.

    COST: Network Load Balancer about USD 0.0252/hour, interface endpoint
    about USD 0.011/hour -- together roughly USD 26/month -- plus USD 0.01/GB.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_privatelink || var.acknowledge_costs
    error_message = "enable_privatelink requires acknowledge_costs = true. The load balancer and endpoint cost about USD 26/month."
  }
}

locals {
  create_privatelink = var.enable_privatelink && var.acknowledge_costs
}

# -----------------------------------------------------------------------------
# Provider side: the shop VPC
# -----------------------------------------------------------------------------

# A NETWORK load balancer: layer 4. It forwards TCP connections and never
# looks inside them. PrivateLink requires one (or a Gateway Load Balancer).
resource "aws_lb" "payment" {
  count = local.create_privatelink ? 1 : 0

  name               = "${local.name_prefix}-payment-nlb"
  load_balancer_type = "network"
  internal           = true
  subnets            = [for key in sort(keys(local.app_subnets)) : module.vpc.private_subnet_ids[key]]

  enable_cross_zone_load_balancing = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-payment-nlb" })
}

resource "aws_lb_target_group" "payment_nlb" {
  count = local.create_privatelink ? 1 : 0

  name        = "${local.name_prefix}-payment-nlb"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"
  protocol    = "TCP"
  port        = local.payment_port

  deregistration_delay = 10

  health_check {
    protocol            = "TCP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-payment-nlb" })
}

resource "aws_lb_target_group_attachment" "payment_nlb" {
  count = local.create_privatelink ? 1 : 0

  target_group_arn = aws_lb_target_group.payment_nlb[0].arn
  target_id        = module.app.instance_id
  port             = local.payment_port
}

resource "aws_lb_listener" "payment_nlb" {
  count = local.create_privatelink ? 1 : 0

  load_balancer_arn = aws_lb.payment[0].arn
  port              = local.payment_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.payment_nlb[0].arn
  }
}

# PrivateLink connections arrive at the app host with a SOURCE address of the
# load balancer's interface in the app subnets -- the consumer's real address
# never appears in the provider VPC. So that is what the app host must allow.
resource "aws_vpc_security_group_ingress_rule" "app_from_nlb" {
  for_each = local.create_privatelink ? local.app_subnets : {}

  security_group_id = module.app.security_group_id
  description       = "Payment port from the PrivateLink load balancer in ${each.key}"
  ip_protocol       = "tcp"
  from_port         = local.payment_port
  to_port           = local.payment_port
  cidr_ipv4         = each.value.cidr_block
}

resource "aws_vpc_endpoint_service" "payment" {
  count = local.create_privatelink ? 1 : 0

  network_load_balancer_arns = [aws_lb.payment[0].arn]

  # Connections from allowed principals are accepted without a manual step.
  # A real provider usually sets this true and approves each consumer.
  acceptance_required = false

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-payment-service" })
}

# Who may create an endpoint to the service. Without this, nobody can --
# not even the account that owns it.
resource "aws_vpc_endpoint_service_allowed_principal" "this_account" {
  count = local.create_privatelink ? 1 : 0

  vpc_endpoint_service_id = aws_vpc_endpoint_service.payment[0].id
  principal_arn           = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
}

# -----------------------------------------------------------------------------
# Consumer side: the dev VPC
# -----------------------------------------------------------------------------
resource "aws_security_group" "payment_endpoint" {
  count = local.create_privatelink ? 1 : 0

  name_prefix = "${local.name_prefix}-payment-vpce-"
  description = "Dev-side access to the payment PrivateLink endpoint"
  vpc_id      = local.vpc_ids["dev"]

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-payment-vpce" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "payment_endpoint" {
  count = local.create_privatelink ? 1 : 0

  security_group_id = aws_security_group.payment_endpoint[0].id
  description       = "Payment port from within the dev VPC"
  ip_protocol       = "tcp"
  from_port         = local.payment_port
  to_port           = local.payment_port
  cidr_ipv4         = local.vpc_cidrs["dev"]
}

resource "aws_vpc_endpoint" "payment" {
  count = local.create_privatelink ? 1 : 0

  vpc_id            = local.vpc_ids["dev"]
  service_name      = aws_vpc_endpoint_service.payment[0].service_name
  vpc_endpoint_type = "Interface"

  subnet_ids         = [module.other_vpc["dev"].public_subnet_ids["public-a"]]
  security_group_ids = [aws_security_group.payment_endpoint[0].id]

  # Private DNS for a custom service needs a verified public domain. A record
  # in the private zone, below, does the same job for this project.
  private_dns_enabled = false

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-payment-vpce" })

  depends_on = [aws_vpc_endpoint_service_allowed_principal.this_account]
}

# A friendly name for the endpoint's generated one.
resource "aws_route53_record" "payments" {
  count = local.create_privatelink ? 1 : 0

  zone_id = aws_route53_zone.private.zone_id
  name    = "payments.${var.private_zone_name}"
  type    = "CNAME"
  ttl     = 60
  records = [aws_vpc_endpoint.payment[0].dns_entry[0].dns_name]
}

output "payment_endpoint_service_name" {
  description = "Service name a consumer uses to create an endpoint to the payment service. Null when PrivateLink is disabled."
  value       = one(aws_vpc_endpoint_service.payment[*].service_name)
}

output "verify_privatelink" {
  description = "Commands for checking PrivateLink. Empty when disabled. The from_dev_* commands run in a shell on the dev host."
  value = local.create_privatelink ? {
    endpoint_state = "aws ec2 describe-vpc-endpoints --vpc-endpoint-ids ${aws_vpc_endpoint.payment[0].id} --region ${var.aws_region} --query 'VpcEndpoints[0].{State:State,Service:ServiceName,Subnets:SubnetIds}' --output json"

    from_dev_endpoint_address_is_local = "dig +short payments.${var.private_zone_name}"
    from_dev_call_payment              = "curl -s http://payments.${var.private_zone_name}:${local.payment_port}/"
    from_dev_still_no_route_to_shop    = "curl -s --max-time 5 http://${module.app.private_ip}:${local.payment_port}/ || echo 'timed out: PrivateLink exchanged no routes'"

    dev_route_table_unchanged = "aws ec2 describe-route-tables --route-table-ids ${local.vpc_route_table_ids["dev"]["public"]} --region ${var.aws_region} --query 'RouteTables[0].Routes' --output table"
  } : {}
}
