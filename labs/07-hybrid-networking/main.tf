# =============================================================================
# Lab 07 -- Hybrid networking
#
#   "on-premises" VPC 192.168.0.0/16          AWS VPC 10.70.0.0/16
#   +---------------------------+             +---------------------------+
#   |  libreswan router         |  IPsec x2   |  virtual private gateway  |
#   |  Elastic IP  <------------+=============+---->  or Transit Gateway  |
#   |  192.168.0.x              |  tunnels    |       10.70.0.x           |
#   +---------------------------+             +---------------------------+
#
# The on-premises side is a second VPC running a REAL IKEv2 daemon, configured
# from the actual pre-shared keys and tunnel addresses AWS generates. The
# tunnels genuinely reach UP; you can watch the state change with the AWS CLI.
# Nothing here is mocked.
#
# COSTS
#   Customer gateway               free
#   Virtual private gateway        free
#   Direct Connect gateway         free (with no virtual interfaces attached)
#   Site-to-Site VPN connection    ~USD 0.05/hour, billed from creation whether
#                                  or not a tunnel ever comes up      (opt-in)
#   Simulated on-premises router   ~USD 0.026/hour                    (opt-in)
#   Transit Gateway attachments    ~USD 0.05/hour each                (opt-in)
#
# SECURITY NOTE: the VPN pre-shared keys AWS generates are stored in Terraform
# state and are marked sensitive in the outputs. Your state bucket is encrypted;
# treat it as a secret store. See SECURITY.md.
# =============================================================================

# -----------------------------------------------------------------------------
# The AWS side
# -----------------------------------------------------------------------------
module "aws_vpc" {
  source = "../../modules/vpc"

  name       = "${local.name_prefix}-aws"
  cidr_block = var.aws_vpc_cidr

  public_subnets          = local.aws_subnets
  create_internet_gateway = true
  nat_gateway_mode        = "none"

  tags = merge(local.common_tags, { Side = "aws" })
}

# A virtual private gateway is the VPN endpoint for exactly ONE VPC. It is free
# to create and free to keep. Its limitation is the reason real designs move to
# a Transit Gateway: a VGW cannot be shared, so ten VPCs needing on-premises
# connectivity means ten VGWs and ten VPN connections.
resource "aws_vpn_gateway" "this" {
  count = local.create_vgw ? 1 : 0

  vpc_id = module.aws_vpc.vpc_id

  # Amazon-side BGP ASN. Only used when the VPN runs BGP, but AWS records it
  # regardless, and it must differ from the customer gateway's ASN.
  amazon_side_asn = 64512

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-vgw" })
}

# Route propagation writes routes learned over the VPN straight into the VPC
# route table. With static routing it propagates the static routes; with BGP it
# propagates what the on-premises router advertises. Without it you would be
# maintaining VPC routes by hand every time the far side changed.
resource "aws_vpn_gateway_route_propagation" "this" {
  count = local.create_vgw ? 1 : 0

  vpn_gateway_id = aws_vpn_gateway.this[0].id
  route_table_id = module.aws_vpc.public_route_table_id
}

# -----------------------------------------------------------------------------
# Transit Gateway alternative -- opt-in
# -----------------------------------------------------------------------------
resource "aws_ec2_transit_gateway" "this" {
  count = local.create_tgw ? 1 : 0

  description                     = "${local.name_prefix} hybrid hub"
  amazon_side_asn                 = 64512
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"

  # Lets several VPN tunnels to the same customer gateway carry traffic
  # simultaneously rather than sitting idle as standby. Only meaningful with BGP.
  vpn_ecmp_support = "enable"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-tgw" })
}

resource "aws_ec2_transit_gateway_vpc_attachment" "aws_vpc" {
  count = local.create_tgw ? 1 : 0

  transit_gateway_id = aws_ec2_transit_gateway.this[0].id
  vpc_id             = module.aws_vpc.vpc_id
  subnet_ids         = [module.aws_vpc.public_subnet_ids["public-a"]]

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-tgw-attach-vpc" })
}

resource "aws_route" "vpc_to_onprem_via_tgw" {
  count = local.create_tgw ? 1 : 0

  route_table_id         = module.aws_vpc.public_route_table_id
  destination_cidr_block = var.on_premises_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this[0].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.aws_vpc]
}

# -----------------------------------------------------------------------------
# Customer gateway -- free
#
# A customer gateway is only a RECORD of your on-premises device: its public IP
# and its BGP ASN. Creating one does nothing on its own and costs nothing.
# -----------------------------------------------------------------------------
resource "aws_customer_gateway" "this" {
  count = local.customer_gateway_ip != null ? 1 : 0

  type       = "ipsec.1"
  ip_address = local.customer_gateway_ip
  bgp_asn    = var.customer_gateway_bgp_asn

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-cgw" })
}

# -----------------------------------------------------------------------------
# Site-to-Site VPN -- ~USD 0.05/hour from the moment it is created
#
# AWS always provisions TWO tunnels to two different endpoints in two different
# Availability Zones. This is not optional and it is not extra cost: one VPN
# connection means two tunnels. With static routing only one carries traffic at
# a time; with BGP and ECMP both can.
# -----------------------------------------------------------------------------
resource "aws_vpn_connection" "this" {
  count = local.create_vpn && local.customer_gateway_ip != null ? 1 : 0

  customer_gateway_id = aws_customer_gateway.this[0].id
  type                = "ipsec.1"

  vpn_gateway_id     = local.create_vgw ? aws_vpn_gateway.this[0].id : null
  transit_gateway_id = local.create_tgw ? aws_ec2_transit_gateway.this[0].id : null

  # Static routing: AWS is told which prefixes live on the far side, rather than
  # learning them from BGP. Simpler, and all the simulated router supports.
  static_routes_only = local.static_routing

  # Pinning IKEv2 removes a whole class of "the tunnel negotiated something
  # unexpected" problems. Left unset, AWS accepts IKEv1 as well, and the two
  # ends can disagree about which to prefer.
  tunnel1_ike_versions = ["ikev2"]
  tunnel2_ike_versions = ["ikev2"]

  # Constraining the proposals to one algorithm set each makes the libreswan
  # configuration below deterministic. In production, leave these unset so AWS
  # offers its full modern set and the strongest mutually supported option wins.
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
  tunnel2_phase2_dh_group_numbers      = [14]
  tunnel1_phase2_dh_group_numbers      = [14]

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-vpn" })
}

# With static routing, AWS needs to be told explicitly which prefixes are
# reachable over the tunnel. With BGP this resource does not exist -- the
# on-premises router advertises them instead.
resource "aws_vpn_connection_route" "on_premises" {
  count = local.create_vpn && local.static_routing && local.customer_gateway_ip != null ? 1 : 0

  vpn_connection_id      = aws_vpn_connection.this[0].id
  destination_cidr_block = var.on_premises_cidr
}

resource "aws_ec2_transit_gateway_route" "on_premises" {
  count = local.create_vpn && local.create_tgw && local.customer_gateway_ip != null ? 1 : 0

  destination_cidr_block         = var.on_premises_cidr
  transit_gateway_route_table_id = aws_ec2_transit_gateway.this[0].association_default_route_table_id
  transit_gateway_attachment_id  = aws_vpn_connection.this[0].transit_gateway_attachment_id
}

# -----------------------------------------------------------------------------
# Direct Connect gateway -- free, and real
#
# A Direct Connect gateway with no virtual interfaces attached costs nothing.
# It is the component that lets ONE Direct Connect connection reach VPCs in
# multiple Regions and multiple accounts.
#
# What cannot be created here is the Direct Connect CONNECTION or a virtual
# interface: those need a physical cross-connect in a colocation facility,
# ordered through AWS or a partner, with a lead time measured in weeks. This
# lab does not pretend otherwise -- see the README for the architecture and the
# Terraform you would write once the circuit exists.
# -----------------------------------------------------------------------------
resource "aws_dx_gateway" "this" {
  count = var.enable_direct_connect_gateway ? 1 : 0

  name            = "${local.name_prefix}-dxgw"
  amazon_side_asn = var.direct_connect_gateway_asn
}

# Associating the Direct Connect gateway with the virtual private gateway is
# also free, and it is the association that would carry traffic once a virtual
# interface existed. Creating it now means the only missing piece really is the
# physical circuit.
resource "aws_dx_gateway_association" "vgw" {
  count = var.enable_direct_connect_gateway && local.create_vgw ? 1 : 0

  dx_gateway_id         = aws_dx_gateway.this[0].id
  associated_gateway_id = aws_vpn_gateway.this[0].id

  # Prefixes AWS will advertise toward on-premises over the Direct Connect
  # gateway. Required for a Transit Gateway association; harmless for a VGW.
  allowed_prefixes = [var.aws_vpc_cidr]
}

# -----------------------------------------------------------------------------
# Simulated on-premises network -- opt-in
# -----------------------------------------------------------------------------
module "on_premises_vpc" {
  count  = local.create_onprem ? 1 : 0
  source = "../../modules/vpc"

  name       = "${local.name_prefix}-onprem"
  cidr_block = var.on_premises_cidr

  public_subnets          = local.onprem_subnets
  create_internet_gateway = true
  nat_gateway_mode        = "none"

  tags = merge(local.common_tags, { Side = "on-premises" })
}

# Allocated as a standalone resource so the customer gateway can reference a
# stable public address before the router instance exists. Associated to the
# instance further down.
resource "aws_eip" "on_premises" {
  count = local.create_onprem ? 1 : 0

  domain = "vpc"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-onprem-eip" })
}

resource "aws_security_group" "on_premises_router" {
  count = local.create_onprem ? 1 : 0

  name_prefix = "${local.name_prefix}-onprem-router-"
  description = "IKE and IPsec from the AWS VPN endpoints, plus traffic from the AWS VPC"
  vpc_id      = module.on_premises_vpc[0].vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-onprem-router-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# IKE negotiation. The instance sits behind the internet gateway's 1:1 NAT, so
# NAT traversal is detected and ESP is encapsulated in UDP 4500 -- which is why
# there is no rule for protocol 50 here.
resource "aws_vpc_security_group_ingress_rule" "onprem_ike" {
  for_each = local.ike_ingress_rules

  security_group_id = aws_security_group.on_premises_router[0].id
  description       = "IKE / NAT-T on UDP ${each.value.port} from AWS VPN endpoint ${each.value.address}"
  ip_protocol       = "udp"
  from_port         = each.value.port
  to_port           = each.value.port

  # Scoped to the two tunnel outside addresses AWS allocated, rather than
  # 0.0.0.0/0. These are the only endpoints that will ever legitimately
  # negotiate with this router.
  cidr_ipv4 = "${each.value.address}/32"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-onprem-ike-${each.key}" })
}

# Traffic arriving from the AWS VPC through the tunnel.
resource "aws_vpc_security_group_ingress_rule" "onprem_from_aws" {
  count = local.create_onprem ? 1 : 0

  security_group_id = aws_security_group.on_premises_router[0].id
  description       = "All traffic from the AWS VPC, arriving over the tunnel"
  ip_protocol       = "-1"
  cidr_ipv4         = var.aws_vpc_cidr

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-onprem-from-aws" })
}

resource "aws_vpc_security_group_ingress_rule" "onprem_local" {
  count = local.create_onprem ? 1 : 0

  security_group_id = aws_security_group.on_premises_router[0].id
  description       = "All traffic from within the simulated on-premises network"
  ip_protocol       = "-1"
  cidr_ipv4         = var.on_premises_cidr

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-onprem-local" })
}

resource "aws_vpc_security_group_egress_rule" "onprem_all" {
  count = local.create_onprem ? 1 : 0

  security_group_id = aws_security_group.on_premises_router[0].id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-onprem-egress" })
}

module "on_premises_router" {
  count  = local.create_onprem ? 1 : 0
  source = "../../modules/test-instance"

  name          = "${local.name_prefix}-onprem-router"
  vpc_id        = module.on_premises_vpc[0].vpc_id
  subnet_id     = module.on_premises_vpc[0].public_subnet_ids["public-a"]
  instance_type = var.on_premises_instance_type
  architecture  = var.instance_architecture

  # This instance forwards packets that are neither addressed to nor sourced
  # from itself. EC2 drops those unless source/destination checking is off --
  # the single most common reason a software router on EC2 "does not work".
  source_dest_check = false

  create_security_group = false
  security_group_ids    = [aws_security_group.on_premises_router[0].id]

  # No public IP here: the Elastic IP is associated separately below, because
  # the customer gateway had to know the address before this instance existed.
  associate_public_ip_address = false

  user_data                   = local.on_premises_user_data
  user_data_replace_on_change = true

  root_volume_size_gb = 8

  tags = merge(local.common_tags, { Side = "on-premises", Role = "vpn-router" })
}

resource "aws_eip_association" "on_premises" {
  count = local.create_onprem ? 1 : 0

  instance_id   = module.on_premises_router[0].instance_id
  allocation_id = aws_eip.on_premises[0].id
}

# Send AWS-bound traffic to the router instance. In a real data centre this is
# the default route on your LAN pointing at the VPN appliance.
resource "aws_route" "onprem_to_aws" {
  count = local.create_onprem ? 1 : 0

  route_table_id         = module.on_premises_vpc[0].public_route_table_id
  destination_cidr_block = var.aws_vpc_cidr
  network_interface_id   = module.on_premises_router[0].primary_network_interface_id
}

# -----------------------------------------------------------------------------
# AWS-side test instance
# -----------------------------------------------------------------------------
module "aws_instance" {
  count  = var.enable_test_instance ? 1 : 0
  source = "../../modules/test-instance"

  name          = "${local.name_prefix}-aws-host"
  vpc_id        = module.aws_vpc.vpc_id
  subnet_id     = module.aws_vpc.public_subnet_ids["public-a"]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  associate_public_ip_address = true

  ingress_rules = {
    icmp_from_onprem = {
      description = "ICMP echo request from the on-premises network, over the tunnel"
      ip_protocol = "icmp"
      from_port   = 8
      to_port     = -1
      cidr_ipv4   = var.on_premises_cidr
    }
    icmp_from_vpc = {
      description = "ICMP echo request from within this VPC"
      ip_protocol = "icmp"
      from_port   = 8
      to_port     = -1
      cidr_ipv4   = var.aws_vpc_cidr
    }
  }

  tags = merge(local.common_tags, { Side = "aws" })
}

check "vpn_is_disabled" {
  assert {
    condition     = local.create_vpn
    error_message = "The Site-to-Site VPN is DISABLED, so this lab has created only the free components: the VPC, the virtual private gateway and (if you supplied an IP) the customer gateway. A VPN connection costs about USD 0.05/hour from the moment it exists. Set acknowledge_costs = true and enable_site_to_site_vpn = true when you are ready."
  }
}

check "on_premises_side_exists" {
  assert {
    condition     = !local.create_vpn || local.create_onprem || var.customer_gateway_ip != null
    error_message = "A VPN connection has been created but there is nothing on the other end: enable_simulated_on_premises is false and customer_gateway_ip is null. The tunnels will stay DOWN and you will be billed about USD 0.05/hour for them. Either enable the simulation or point customer_gateway_ip at a real device."
  }
}
