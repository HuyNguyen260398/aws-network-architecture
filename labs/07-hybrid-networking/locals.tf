locals {
  lab_name    = "07-hybrid-networking"
  name_prefix = "${var.project_name}-lab07"

  common_tags = merge(
    {
      Project     = var.project_name
      Lab         = local.lab_name
      Environment = "learning"
      ManagedBy   = "terraform"
      Lifecycle   = "ephemeral"
    },
    var.additional_tags,
  )

  create_vpn     = var.enable_site_to_site_vpn && var.acknowledge_costs
  create_onprem  = local.create_vpn && var.enable_simulated_on_premises
  create_tgw     = var.enable_transit_gateway_attachment && var.acknowledge_costs
  create_vgw     = !local.create_tgw
  static_routing = !var.use_bgp

  # The customer gateway needs a public IP before the on-premises instance
  # exists, and the instance's configuration needs the VPN's tunnel parameters,
  # which need the customer gateway. Allocating the Elastic IP as a standalone
  # resource and associating it afterwards is what breaks that cycle.
  customer_gateway_ip = local.create_onprem ? aws_eip.on_premises[0].public_ip : var.customer_gateway_ip

  aws_subnets = {
    "public-a" = {
      cidr_block              = cidrsubnet(var.aws_vpc_cidr, var.subnet_newbits, 0)
      az_index                = 0
      map_public_ip_on_launch = true
    }
    "public-b" = {
      cidr_block              = cidrsubnet(var.aws_vpc_cidr, var.subnet_newbits, 1)
      az_index                = 1
      map_public_ip_on_launch = false
    }
  }

  onprem_subnets = {
    "public-a" = {
      cidr_block              = cidrsubnet(var.on_premises_cidr, var.subnet_newbits, 0)
      az_index                = 0
      map_public_ip_on_launch = true
    }
  }

  # IKE and NAT-T must be reachable from BOTH of the AWS tunnel endpoints. The
  # map is built here rather than inline so each rule gets a stable resource
  # address keyed by tunnel and port.
  ike_ingress_rules = local.create_onprem ? {
    "tunnel1-500"  = { port = 500, address = aws_vpn_connection.this[0].tunnel1_address }
    "tunnel1-4500" = { port = 4500, address = aws_vpn_connection.this[0].tunnel1_address }
    "tunnel2-500"  = { port = 500, address = aws_vpn_connection.this[0].tunnel2_address }
    "tunnel2-4500" = { port = 4500, address = aws_vpn_connection.this[0].tunnel2_address }
  } : {}

  # Rendered from the real tunnel parameters AWS generated. Contains the
  # pre-shared keys, so it is sensitive: it lands in Terraform state and in the
  # instance's user data, which is readable from the instance metadata service.
  on_premises_user_data = local.create_onprem ? templatefile("${path.module}/templates/on-premises-router.sh.tftpl", {
    on_premises_public_ip = aws_eip.on_premises[0].public_ip
    on_premises_cidr      = var.on_premises_cidr
    aws_vpc_cidr          = var.aws_vpc_cidr
    tunnel1_address       = aws_vpn_connection.this[0].tunnel1_address
    tunnel2_address       = aws_vpn_connection.this[0].tunnel2_address
    tunnel1_preshared_key = aws_vpn_connection.this[0].tunnel1_preshared_key
    tunnel2_preshared_key = aws_vpn_connection.this[0].tunnel2_preshared_key
  }) : null

  estimated_hourly_usd = (
    (local.create_vpn ? 0.05 : 0)
    + (local.create_tgw ? 0.10 : 0)
    + (local.create_onprem ? 0.0212 + 0.005 : 0)
    + (var.enable_test_instance ? 0.0053 + 0.005 : 0)
  )
}
