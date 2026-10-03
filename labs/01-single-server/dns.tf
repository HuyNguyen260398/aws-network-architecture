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

# An A record: name -> IPv4 address. Short TTL because the address changes
# whenever the server is replaced -- a weakness lab 05 removes.
resource "aws_route53_record" "shop" {
  count = var.public_zone_name == null ? 0 : 1

  zone_id = data.aws_route53_zone.public[0].zone_id
  name    = "${var.shop_record_name}.${var.public_zone_name}"
  type    = "A"
  ttl     = 60
  records = [module.server.public_ip]
}

output "shop_hostname" {
  description = "DNS name of the shop, or null when public_zone_name is not set."
  value       = one(aws_route53_record.shop[*].fqdn)
}
