# =============================================================================
# Outbound access for the private tiers.
#
# The app and database hosts have private addresses only. Private addresses
# are not routable on the internet, so a packet from 10.10.10.x would reach
# its destination and the reply would have nowhere to go.
#
# NAT fixes that. The NAT gateway sits in a public subnet with a public
# address of its own. It rewrites the SOURCE address of each outbound packet
# to that public address, remembers the connection, and rewrites the reply
# back. Many private hosts share one public address, and nothing on the
# internet can open a connection to them.
#
# The resources are created inside modules/vpc; this file holds the switches.
# =============================================================================

variable "acknowledge_costs" {
  description = "Set to true to confirm you understand that the opt-in resources are billed by the hour and that you will destroy them when finished. Required before any enable_* flag for a chargeable resource can take effect."
  type        = bool
  default     = false
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Create a NAT gateway so the private subnets can reach the internet outbound.

    COST: roughly USD 0.059/hour in ap-southeast-1 -- about USD 43/month, or
    USD 1.42/day -- PLUS roughly USD 0.059 per GB processed. This is the single
    most common source of surprise charges in an AWS learning account.

    Leave it false and the private subnets have no default route at all. That
    is a perfectly good state for learning: it demonstrates isolation, and the
    Session Manager failure it causes is itself a lesson.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_nat_gateway || var.acknowledge_costs
    error_message = "enable_nat_gateway requires acknowledge_costs = true. A NAT gateway costs about USD 43/month plus data processing charges."
  }
}

variable "nat_gateway_mode" {
  description = "\"single\" creates one NAT gateway shared by every Availability Zone: cheapest, but a failure of its zone cuts off outbound access for all of them, and traffic from the other zone pays cross-zone data transfer. \"per_az\" creates one per zone."
  type        = string
  default     = "single"

  validation {
    condition     = contains(["single", "per_az"], var.nat_gateway_mode)
    error_message = "nat_gateway_mode must be \"single\" or \"per_az\"."
  }
}

variable "enable_ipv6" {
  description = "Give the VPC an Amazon-provided IPv6 /56 and every subnet a /64. Free. IPv6 addresses are all globally routable, so there is no NAT; privacy comes from routing alone."
  type        = bool
  default     = false
}

variable "enable_egress_only_internet_gateway" {
  description = "With enable_ipv6, route the private subnets' ::/0 to an egress-only internet gateway: outbound connections allowed, unsolicited inbound dropped. The IPv6 equivalent of a NAT gateway, at no charge."
  type        = bool
  default     = true
}

locals {
  # Two gates: the feature flag and the cost acknowledgement. The validation on
  # enable_nat_gateway already refuses the combination, so this is belt and
  # braces for anyone who edits the variable defaults.
  nat_gateway_mode = var.enable_nat_gateway && var.acknowledge_costs ? var.nat_gateway_mode : "none"

  # An egress-only internet gateway is meaningless without IPv6.
  enable_eoigw = var.enable_ipv6 && var.enable_egress_only_internet_gateway
}

output "nat_gateway_public_ips" {
  description = "Public addresses of the NAT gateways. Every outbound connection from a private host appears on the internet to come from one of these."
  value       = module.vpc.nat_gateway_public_ips
}

output "vpc_ipv6_cidr_block" {
  description = "The /56 Amazon assigned to the VPC, or null when IPv6 is off."
  value       = module.vpc.vpc_ipv6_cidr_block
}

output "ssm_app" {
  description = "Open a shell on the app server. Works only once the private tiers have a path to Systems Manager: the NAT gateway here, or the endpoints in lab 04."
  value       = module.app.ssm_start_session_command
}

output "ssm_db" {
  description = "Open a shell on the database server. Same condition as ssm_app."
  value       = module.db.ssm_start_session_command
}

output "verify_nat" {
  description = "Commands for checking outbound access. Run the last one from a shell on the app server."
  value = {
    nat_gateways = "aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=${module.vpc.vpc_id} --region ${var.aws_region} --query 'NatGateways[].{Id:NatGatewayId,State:State,Subnet:SubnetId,PublicIP:NatGatewayAddresses[0].PublicIp}' --output table"

    which_instances_registered_with_ssm = "aws ssm describe-instance-information --region ${var.aws_region} --query 'InstanceInformationList[].{Id:InstanceId,Ping:PingStatus,IP:IPAddress}' --output table"

    from_app_source_address_seen_by_internet = "curl -s https://checkip.amazonaws.com"
  }
}
