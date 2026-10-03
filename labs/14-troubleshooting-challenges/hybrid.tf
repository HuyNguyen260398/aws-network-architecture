# =============================================================================
# Hybrid networking: the office joins the network.
#
# The company's office has its own network, 192.168.0.0/16, and its staff need
# to reach the shop's private addresses. A Site-to-Site VPN is an encrypted
# tunnel over the internet between a device at the office (the CUSTOMER
# GATEWAY) and AWS (here a VIRTUAL PRIVATE GATEWAY on the shop VPC).
#
# There is no office. It is simulated by one more VPC, in an address range that
# looks nothing like AWS, containing one EC2 instance running libreswan. From
# AWS's point of view that instance is indistinguishable from a real router:
# it has a public address, it speaks IKEv2, and it holds the pre-shared keys.
# =============================================================================

variable "office_cidr" {
  description = "IPv4 range of the office network. Deliberately outside the 10.0.0.0/8 supernet: on-premises ranges are rarely yours to choose, and the routes for them have to be added explicitly."
  type        = string
  default     = "192.168.0.0/16"

  validation {
    condition     = can(cidrhost(var.office_cidr, 0)) && cidrhost(var.office_cidr, 0) == split("/", var.office_cidr)[0]
    error_message = "office_cidr must be a valid IPv4 network address with all host bits zero."
  }
}

variable "enable_site_to_site_vpn" {
  description = <<-EOT
    Create the Site-to-Site VPN connection.

    COST: about USD 0.05 per hour from the moment the connection exists,
    whether or not either tunnel is up -- USD 36/month -- plus data transfer.
    The simulated office adds a t4g.small and an Elastic IP, about
    USD 0.026/hour.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_site_to_site_vpn || var.acknowledge_costs
    error_message = "enable_site_to_site_vpn requires acknowledge_costs = true. A VPN connection costs about USD 36/month."
  }
}

variable "enable_simulated_office" {
  description = "With the VPN enabled, also build the simulated office: a VPC and a libreswan router configured from the real tunnel parameters. Set false only if customer_gateway_ip points at a device of your own."
  type        = bool
  default     = true
}

variable "customer_gateway_ip" {
  description = "Public IPv4 address of a real VPN device, used when enable_simulated_office is false. Null otherwise."
  type        = string
  default     = null

  validation {
    condition     = var.customer_gateway_ip == null || can(cidrhost("${var.customer_gateway_ip}/32", 0))
    error_message = "customer_gateway_ip must be an IPv4 address."
  }
}

variable "customer_gateway_bgp_asn" {
  description = "BGP autonomous system number recorded for the office device. Required by the API even though this lab uses static routes."
  type        = number
  default     = 65000
}

variable "office_instance_type" {
  description = "Instance type of the simulated office router. IPsec is CPU work; a t4g.nano struggles."
  type        = string
  default     = "t4g.small"
}

variable "enable_direct_connect_gateway" {
  description = "Create a Direct Connect gateway and associate it with the virtual private gateway. Free, and the only part of Direct Connect that can be created without a physical circuit. It carries no traffic."
  type        = bool
  default     = false
}

locals {
  create_vpn    = var.enable_site_to_site_vpn && var.acknowledge_costs
  create_office = local.create_vpn && var.enable_simulated_office

  customer_gateway_ip = local.create_office ? aws_eip.office[0].public_ip : var.customer_gateway_ip
  create_vpn_tunnels  = local.create_vpn && (local.create_office || var.customer_gateway_ip != null)

  # The office router accepts IKE (UDP 500) and NAT-traversal (UDP 4500) from
  # the two AWS tunnel endpoints and from nowhere else.
  ike_ingress_rules = local.create_office ? {
    "tunnel1-500"  = { port = 500, address = aws_vpn_connection.office[0].tunnel1_address }
    "tunnel1-4500" = { port = 4500, address = aws_vpn_connection.office[0].tunnel1_address }
    "tunnel2-500"  = { port = 500, address = aws_vpn_connection.office[0].tunnel2_address }
    "tunnel2-4500" = { port = 4500, address = aws_vpn_connection.office[0].tunnel2_address }
  } : {}

  office_user_data = local.create_office ? templatefile("${path.module}/templates/office-router.sh.tftpl", {
    on_premises_public_ip = aws_eip.office[0].public_ip
    on_premises_cidr      = var.office_cidr
    aws_vpc_cidr          = var.vpc_cidr
    tunnel1_address       = aws_vpn_connection.office[0].tunnel1_address
    tunnel2_address       = aws_vpn_connection.office[0].tunnel2_address
    tunnel1_preshared_key = aws_vpn_connection.office[0].tunnel1_preshared_key
    tunnel2_preshared_key = aws_vpn_connection.office[0].tunnel2_preshared_key
  }) : null
}

# -----------------------------------------------------------------------------
# AWS side
# -----------------------------------------------------------------------------

# The VPN's anchor on the shop VPC. Free, so it exists whether or not the VPN
# does.
resource "aws_vpn_gateway" "shop" {
  vpc_id          = module.vpc.vpc_id
  amazon_side_asn = 64513

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-vgw" })
}

# Route PROPAGATION: the gateway writes the routes it knows -- the office range
# -- into these route tables itself. No aws_route resource names the office.
resource "aws_vpn_gateway_route_propagation" "shop" {
  for_each = local.vpc_route_table_ids["shop"]

  vpn_gateway_id = aws_vpn_gateway.shop.id
  route_table_id = each.value
}

# A customer gateway is only a record: "there is a device at this address".
resource "aws_customer_gateway" "office" {
  count = local.create_vpn_tunnels ? 1 : 0

  type       = "ipsec.1"
  ip_address = local.customer_gateway_ip
  bgp_asn    = var.customer_gateway_bgp_asn

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-cgw-office" })
}

resource "aws_vpn_connection" "office" {
  count = local.create_vpn_tunnels ? 1 : 0

  customer_gateway_id = aws_customer_gateway.office[0].id
  vpn_gateway_id      = aws_vpn_gateway.shop.id
  type                = "ipsec.1"

  # Static routes: each side is told the other's range. The alternative is
  # BGP, where the two routers tell each other and failover is automatic.
  static_routes_only = true

  # AWS always provisions TWO tunnels, to endpoints in two Availability Zones.
  # The algorithms are pinned rather than negotiated so both ends are known to
  # match, and so nothing falls back to something weaker.
  tunnel1_ike_versions                 = ["ikev2"]
  tunnel2_ike_versions                 = ["ikev2"]
  tunnel1_phase1_encryption_algorithms = ["AES256"]
  tunnel2_phase1_encryption_algorithms = ["AES256"]
  tunnel1_phase2_encryption_algorithms = ["AES256"]
  tunnel2_phase2_encryption_algorithms = ["AES256"]
  tunnel1_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase1_dh_group_numbers      = [14]
  tunnel2_phase1_dh_group_numbers      = [14]
  tunnel1_phase2_dh_group_numbers      = [14]
  tunnel2_phase2_dh_group_numbers      = [14]

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-vpn-office" })
}

# What is at the far end of the tunnel. The gateway propagates this.
resource "aws_vpn_connection_route" "office" {
  count = local.create_vpn_tunnels ? 1 : 0

  vpn_connection_id      = aws_vpn_connection.office[0].id
  destination_cidr_block = var.office_cidr
}

# Office staff reach the frontend on its PRIVATE address, and can ping the
# web and app hosts. Nothing else in the shop opens to them.
resource "aws_vpc_security_group_ingress_rule" "web_from_office" {
  security_group_id = module.web.security_group_id
  description       = "Shop frontend from the office, over the VPN"
  ip_protocol       = "tcp"
  from_port         = local.frontend_port
  to_port           = local.frontend_port
  cidr_ipv4         = var.office_cidr
}

resource "aws_vpc_security_group_ingress_rule" "shop_icmp_from_office" {
  for_each = {
    web = module.web.security_group_id
    app = module.app.security_group_id
  }

  security_group_id = each.value
  description       = "ICMP echo request from the office, over the VPN"
  ip_protocol       = "icmp"
  from_port         = 8
  to_port           = -1
  cidr_ipv4         = var.office_cidr
}

# The inbound Resolver endpoint from lab 11 is what lets the office resolve
# shop.internal. It must accept DNS from the office range.
resource "aws_vpc_security_group_ingress_rule" "resolver_from_office" {
  for_each = local.create_resolver_any ? toset(["udp", "tcp"]) : toset([])

  security_group_id = aws_security_group.resolver[0].id
  description       = "DNS over ${upper(each.value)} from the office, over the VPN"
  ip_protocol       = each.value
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = var.office_cidr
}

# -----------------------------------------------------------------------------
# Direct Connect gateway -- free, optional, carries nothing
#
# Direct Connect is a private physical circuit instead of a tunnel over the
# internet. The circuit cannot be created from Terraform alone: it involves a
# colocation facility and weeks of lead time. This is the one piece that can.
# -----------------------------------------------------------------------------
resource "aws_dx_gateway" "this" {
  count = var.enable_direct_connect_gateway ? 1 : 0

  name            = "${local.name_prefix}-dxgw"
  amazon_side_asn = 64514
}

resource "aws_dx_gateway_association" "vgw" {
  count = var.enable_direct_connect_gateway ? 1 : 0

  dx_gateway_id         = aws_dx_gateway.this[0].id
  associated_gateway_id = aws_vpn_gateway.shop.id

  # What AWS would advertise to the office over the circuit.
  allowed_prefixes = [var.vpc_cidr]
}

# -----------------------------------------------------------------------------
# The simulated office
# -----------------------------------------------------------------------------
module "office_vpc" {
  count  = local.create_office ? 1 : 0
  source = "../../modules/vpc"

  name       = "${local.name_prefix}-office"
  cidr_block = var.office_cidr

  public_subnets = {
    "public-a" = {
      cidr_block              = cidrsubnet(var.office_cidr, 8, 0)
      az_index                = 0
      map_public_ip_on_launch = true
    }
  }
  create_internet_gateway = true

  tags = merge(local.common_tags, { Vpc = "office" })
}

# The office's public address. An Elastic IP, because the customer gateway
# record and the router's own IKE identity must both name it before the
# instance exists.
resource "aws_eip" "office" {
  #checkov:skip=CKV2_AWS_19:Attached by aws_eip_association.office below. It cannot be attached inline because the customer gateway and the router's own configuration both need the address before the instance exists.
  count = local.create_office ? 1 : 0

  domain = "vpc"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-office-router" })
}

resource "aws_security_group" "office_router" {
  count = local.create_office ? 1 : 0

  name_prefix = "${local.name_prefix}-office-router-"
  description = "IKE and IPsec from the AWS VPN endpoints, plus traffic from the shop VPC"
  vpc_id      = module.office_vpc[0].vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-office-router" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "office_ike" {
  for_each = local.ike_ingress_rules

  security_group_id = aws_security_group.office_router[0].id
  description       = "IKE / NAT-T on UDP ${each.value.port} from an AWS VPN endpoint"
  ip_protocol       = "udp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = "${each.value.address}/32"
}

resource "aws_vpc_security_group_ingress_rule" "office_from_shop" {
  count = local.create_office ? 1 : 0

  security_group_id = aws_security_group.office_router[0].id
  description       = "All traffic from the shop VPC, arriving over the tunnel"
  ip_protocol       = "-1"
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_security_group_ingress_rule" "office_local" {
  count = local.create_office ? 1 : 0

  security_group_id = aws_security_group.office_router[0].id
  description       = "All traffic from within the office network"
  ip_protocol       = "-1"
  cidr_ipv4         = var.office_cidr
}

resource "aws_vpc_security_group_egress_rule" "office_all" {
  count = local.create_office ? 1 : 0

  security_group_id = aws_security_group.office_router[0].id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

module "office_router" {
  count  = local.create_office ? 1 : 0
  source = "../../modules/test-instance"

  name          = "${local.name_prefix}-office-router"
  vpc_id        = module.office_vpc[0].vpc_id
  subnet_id     = module.office_vpc[0].public_subnet_ids["public-a"]
  instance_type = var.office_instance_type
  architecture  = var.instance_architecture

  # A router forwards packets that are not addressed to it. EC2 drops those
  # by default; this turns the check off.
  source_dest_check = false

  create_security_group = false
  security_group_ids    = [aws_security_group.office_router[0].id]

  # The Elastic IP is attached below.
  associate_public_ip_address = false

  user_data                   = local.office_user_data
  user_data_replace_on_change = true

  tags = merge(local.common_tags, { Vpc = "office" })
}

resource "aws_eip_association" "office" {
  count = local.create_office ? 1 : 0

  instance_id   = module.office_router[0].instance_id
  allocation_id = aws_eip.office[0].id
}

# Inside the office, traffic for the shop goes to the router, which puts it in
# the tunnel. On a real office network this is the default gateway's job.
resource "aws_route" "office_to_shop" {
  count = local.create_office ? 1 : 0

  route_table_id         = module.office_vpc[0].public_route_table_id
  destination_cidr_block = var.vpc_cidr
  network_interface_id   = module.office_router[0].primary_network_interface_id
}

check "vpn_is_disabled" {
  assert {
    condition     = local.create_vpn
    error_message = "The Site-to-Site VPN is DISABLED, so this lab has created only the free component: the virtual private gateway. A VPN connection costs about USD 0.05/hour from the moment it exists. Set acknowledge_costs = true and enable_site_to_site_vpn = true when you are ready."
  }
}

check "office_side_exists" {
  assert {
    condition     = !local.create_vpn || local.create_vpn_tunnels
    error_message = "The VPN is enabled but there is nothing to connect to: enable_simulated_office is false and customer_gateway_ip is null, so no connection was created. Enable the simulation or point customer_gateway_ip at a real device."
  }
}

output "vpn_gateway_id" {
  description = "ID of the virtual private gateway on the shop VPC."
  value       = aws_vpn_gateway.shop.id
}

output "vpn_connection_id" {
  description = "ID of the Site-to-Site VPN connection, or null when disabled."
  value       = one(aws_vpn_connection.office[*].id)
}

output "office_router_public_ip" {
  description = "Public address of the simulated office router -- the customer gateway address. Null when not simulated."
  value       = one(aws_eip.office[*].public_ip)
}

output "ssm_office_router" {
  description = "Open a shell on the simulated office router."
  value       = one(module.office_router[*].ssm_start_session_command)
}

output "verify_hybrid" {
  description = "Commands for checking the VPN. Empty when disabled. The from_office_* commands run in a shell on the office router."
  value = local.create_vpn_tunnels ? {
    tunnel_status = "aws ec2 describe-vpn-connections --vpn-connection-ids ${aws_vpn_connection.office[0].id} --region ${var.aws_region} --query 'VpnConnections[0].VgwTelemetry[].{Outside:OutsideIpAddress,Status:Status,Message:StatusMessage}' --output table"

    propagated_routes = "aws ec2 describe-route-tables --route-table-ids ${module.vpc.public_route_table_id} --region ${var.aws_region} --query 'RouteTables[0].Routes[].{Dest:DestinationCidrBlock,Gateway:GatewayId,Origin:Origin}' --output table"

    from_office_tunnel_status   = "sudo tunnel-status"
    from_office_ping_web        = "ping -c 3 ${module.web.private_ip}"
    from_office_frontend        = "curl -s http://${module.web.private_ip}/"
    from_office_database_closed = "curl -s --max-time 5 http://${module.db.private_ip}:${local.database_port}/ || echo 'timed out, as intended'"
  } : {}
}
