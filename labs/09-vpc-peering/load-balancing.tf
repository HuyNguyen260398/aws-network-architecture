# =============================================================================
# Load balancing.
#
# Until now the shop was one web server with one public address. If that
# server is replaced its address changes, and there can only ever be one.
#
# An Application Load Balancer gives the shop a single stable entry point and
# decides, per request, which backend answers. It works at layer 7: it reads
# the HTTP request and routes on what it finds there.
#
#   by PATH   /pay/*            -> payment service (app tier, :9090)
#   by HOST   pay.<anything>    -> payment service
#   default   everything else   -> frontend        (web tier, :80)
#
# This is the same job a Kubernetes Ingress does in lab 07.
# =============================================================================

variable "enable_load_balancer" {
  description = <<-EOT
    Put an Application Load Balancer in front of the shop.

    COST: roughly USD 0.0252/hour in ap-southeast-1 -- about USD 18/month --
    plus load balancer capacity units, which a lab barely uses, plus two
    public IPv4 addresses (one per Availability Zone) at USD 0.005/hour each.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_load_balancer || var.acknowledge_costs
    error_message = "enable_load_balancer requires acknowledge_costs = true. An Application Load Balancer costs about USD 18/month plus usage."
  }
}

locals {
  load_balancer_enabled = var.enable_load_balancer && var.acknowledge_costs

  # Backends the load balancer can send to. Lab 06 adds containers.
  alb_instance_targets = {
    frontend = { port = local.frontend_port, instance_id = module.web.instance_id, security_group_id = module.web.security_group_id }
    payment  = { port = local.payment_port, instance_id = module.app.instance_id, security_group_id = module.app.security_group_id }
  }
}

# -----------------------------------------------------------------------------
# The load balancer and its own firewall
# -----------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  count = local.load_balancer_enabled ? 1 : 0

  name_prefix = "${local.name_prefix}-alb-"
  description = "Shop load balancer: HTTP in from clients, out to the backends only"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  count = local.load_balancer_enabled ? 1 : 0

  security_group_id = aws_security_group.alb[0].id
  description       = "HTTP from clients"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = var.allowed_client_cidr
}

# The load balancer may talk to each backend on that backend's port, and to
# nothing else.
resource "aws_vpc_security_group_egress_rule" "alb_to_target" {
  for_each = local.load_balancer_enabled ? local.alb_instance_targets : {}

  security_group_id            = aws_security_group.alb[0].id
  description                  = "To the ${each.key} backend"
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  referenced_security_group_id = each.value.security_group_id
}

# ...and each backend accepts its port from the load balancer's group. For the
# web tier this replaces the rule that allowed the whole internet.
resource "aws_vpc_security_group_ingress_rule" "target_from_alb" {
  for_each = local.load_balancer_enabled ? local.alb_instance_targets : {}

  security_group_id            = each.value.security_group_id
  description                  = "${each.key} from the load balancer"
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  referenced_security_group_id = aws_security_group.alb[0].id
}

resource "aws_lb" "shop" {
  count = local.load_balancer_enabled ? 1 : 0

  name               = "${local.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false

  # One subnet per Availability Zone. The load balancer puts a node in each,
  # which is why lab 02 built two public subnets.
  subnets         = [for key in sort(keys(local.public_subnets)) : module.vpc.public_subnet_ids[key]]
  security_groups = [aws_security_group.alb[0].id]

  drop_invalid_header_fields = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-alb" })
}

# -----------------------------------------------------------------------------
# Backends
# -----------------------------------------------------------------------------
resource "aws_lb_target_group" "instance" {
  for_each = local.load_balancer_enabled ? local.alb_instance_targets : {}

  name        = "${local.name_prefix}-${each.key}"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"
  protocol    = "HTTP"
  port        = each.value.port

  # Short, so that replacing a backend during an exercise does not mean a
  # five-minute wait for connections to drain.
  deregistration_delay = 10

  # The load balancer only forwards to backends that answer this. A backend
  # that stops answering is taken out of rotation without anyone noticing.
  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-${each.key}" })
}

resource "aws_lb_target_group_attachment" "instance" {
  for_each = local.load_balancer_enabled ? local.alb_instance_targets : {}

  target_group_arn = aws_lb_target_group.instance[each.key].arn
  target_id        = each.value.instance_id
  port             = each.value.port
}

# -----------------------------------------------------------------------------
# Listener and routing rules
# -----------------------------------------------------------------------------

# HTTP only. HTTPS needs a certificate, a certificate needs a domain you
# control, and the labs cannot assume you have one. The README covers what
# changes when you do.
resource "aws_lb_listener" "http" {
  count = local.load_balancer_enabled ? 1 : 0

  load_balancer_arn = aws_lb.shop[0].arn
  port              = 80
  protocol          = "HTTP"

  # Whatever no rule matches goes to the frontend.
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.instance["frontend"].arn
  }
}

# Rules are evaluated in priority order, lowest number first, first match wins.
resource "aws_lb_listener_rule" "payment_by_path" {
  count = local.load_balancer_enabled ? 1 : 0

  listener_arn = aws_lb_listener.http[0].arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.instance["payment"].arn
  }

  condition {
    path_pattern {
      values = ["/pay", "/pay/*"]
    }
  }
}

resource "aws_lb_listener_rule" "payment_by_host" {
  count = local.load_balancer_enabled ? 1 : 0

  listener_arn = aws_lb_listener.http[0].arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.instance["payment"].arn
  }

  # Matches the Host header, so it works with any name that resolves to the
  # load balancer -- or with none, using `curl -H 'Host: pay.shop.test'`.
  condition {
    host_header {
      values = ["pay.*"]
    }
  }
}

output "load_balancer_dns_name" {
  description = "DNS name of the load balancer, or null when disabled. It is a name and not an address because the addresses behind it change."
  value       = one(aws_lb.shop[*].dns_name)
}

output "shop_url" {
  description = "Where the shop is reached now: the load balancer when it is enabled, otherwise the web server directly."
  value       = local.load_balancer_enabled ? "http://${aws_lb.shop[0].dns_name}/" : "http://${module.web.public_ip}/"
}

output "verify_load_balancer" {
  description = "Commands for checking the load balancer. Empty when it is disabled."
  value = local.load_balancer_enabled ? {
    default_rule_frontend = "curl -s http://${aws_lb.shop[0].dns_name}/"
    path_rule_payment     = "curl -s http://${aws_lb.shop[0].dns_name}/pay/checkout"
    host_rule_payment     = "curl -s -H 'Host: pay.shop.test' http://${aws_lb.shop[0].dns_name}/"

    load_balancer_addresses = "dig +short ${aws_lb.shop[0].dns_name}"

    web_no_longer_direct = "curl -s --max-time 5 http://${module.web.public_ip}/ || echo 'timed out, as intended'"

    target_health = "for tg in ${join(" ", [for k in sort(keys(aws_lb_target_group.instance)) : aws_lb_target_group.instance[k].arn])}; do aws elbv2 describe-target-health --target-group-arn $tg --region ${var.aws_region} --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State}' --output table; done"

    listener_rules = "aws elbv2 describe-rules --listener-arn ${aws_lb_listener.http[0].arn} --region ${var.aws_region} --query 'Rules[].{Priority:Priority,Conditions:Conditions[].Values|[0],Target:Actions[0].TargetGroupArn}' --output table"
  } : {}
}
