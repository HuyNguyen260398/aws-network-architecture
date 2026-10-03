# =============================================================================
# The name.
#
# People remember names, packets need addresses, DNS maps one to the other.
# This file is optional: without a hosted zone the shop is still reachable by
# its public IP and by the name AWS assigns to every public address.
# =============================================================================

variable "public_zone_name" {
  description = "Name of an existing Route 53 PUBLIC hosted zone you own, for example example.com. When set, a record shop.<zone> is created. Null skips DNS; the shop is then reached by IP address or by its AWS-assigned public DNS name."
  type        = string
  default     = null
}

variable "shop_record_name" {
  description = "Host label for the shop inside public_zone_name."
  type        = string
  default     = "shop"
}

data "aws_route53_zone" "public" {
  count = var.public_zone_name == null ? 0 : 1

  name         = var.public_zone_name
  private_zone = false
}

# Without a load balancer: an A record, name -> the web server's address.
# Short TTL because that address changes whenever the server is replaced.
resource "aws_route53_record" "shop" {
  count = var.public_zone_name != null && !local.load_balancer_enabled ? 1 : 0

  zone_id = data.aws_route53_zone.public[0].zone_id
  name    = "${var.shop_record_name}.${var.public_zone_name}"
  type    = "A"
  ttl     = 60
  records = [module.web.public_ip]
}

# With a load balancer: an ALIAS record. A load balancer has no fixed address
# -- its nodes come and go -- so the record points at the load balancer itself
# and Route 53 answers with whatever addresses it has at that moment. The
# wildcard makes pay.shop.<zone> resolve too, for host-based routing.
resource "aws_route53_record" "shop_alias" {
  for_each = var.public_zone_name != null && local.load_balancer_enabled ? toset(["", "*."]) : toset([])

  zone_id = data.aws_route53_zone.public[0].zone_id
  name    = "${each.value}${var.shop_record_name}.${var.public_zone_name}"
  type    = "A"

  alias {
    name                   = aws_lb.shop[0].dns_name
    zone_id                = aws_lb.shop[0].zone_id
    evaluate_target_health = true
  }
}

output "shop_hostname" {
  description = "DNS name of the shop, or null when public_zone_name is not set."
  value       = var.public_zone_name == null ? null : "${var.shop_record_name}.${var.public_zone_name}"
}
