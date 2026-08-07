variable "aws_region" {
  description = "Region to deploy the lab into."
  type        = string
  default     = "ap-southeast-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must look like an AWS Region identifier, for example ap-southeast-1."
  }
}

variable "project_name" {
  description = "Prefix for resource names and the Project tag."
  type        = string
  default     = "awsnet"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,20}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-22 lowercase characters, digits or hyphens."
  }
}

variable "aws_vpc_cidr" {
  description = "CIDR for the AWS-side VPC -- the 'cloud' end of the hybrid connection."
  type        = string
  default     = "10.70.0.0/16"

  validation {
    condition     = can(cidrhost(var.aws_vpc_cidr, 0)) && cidrhost(var.aws_vpc_cidr, 0) == split("/", var.aws_vpc_cidr)[0]
    error_message = "aws_vpc_cidr must be a valid IPv4 network address with all host bits zero."
  }
}

variable "on_premises_cidr" {
  description = <<-EOT
    CIDR representing the on-premises network. Deliberately from a different
    RFC 1918 block (192.168.0.0/16) than the AWS VPCs in this repository, which
    is exactly the discipline a real hybrid design needs: the corporate network
    and the cloud network must never overlap, or the VPN can carry no traffic
    between them.
  EOT
  type        = string
  default     = "192.168.0.0/16"

  validation {
    condition     = can(cidrhost(var.on_premises_cidr, 0)) && cidrhost(var.on_premises_cidr, 0) == split("/", var.on_premises_cidr)[0]
    error_message = "on_premises_cidr must be a valid IPv4 network address with all host bits zero."
  }
}

variable "subnet_newbits" {
  description = "Bits added to each VPC prefix when carving subnets."
  type        = number
  default     = 8

  validation {
    condition     = var.subnet_newbits >= 1 && var.subnet_newbits <= 12
    error_message = "subnet_newbits must be between 1 and 12."
  }
}

# -----------------------------------------------------------------------------
# Cost gates
# -----------------------------------------------------------------------------
variable "acknowledge_costs" {
  description = "Confirms you understand that a Site-to-Site VPN connection and any Transit Gateway attachment are billed per hour. Required before enable_site_to_site_vpn can take effect."
  type        = bool
  default     = false
}

variable "enable_site_to_site_vpn" {
  description = <<-EOT
    Create the AWS Site-to-Site VPN connection.

    COST: about USD 0.05 per VPN-connection-hour (~USD 36/month) plus data
    transfer. A VPN connection is billed from creation, whether or not either
    tunnel ever comes up.

    With this false the lab still creates the VPC, the virtual private gateway
    and the customer gateway -- all free -- so you can read the topology and the
    Terraform at no cost.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_site_to_site_vpn || var.acknowledge_costs
    error_message = "enable_site_to_site_vpn requires acknowledge_costs = true. A VPN connection costs about USD 0.05/hour (USD 36/month) from the moment it is created."
  }
}

variable "enable_simulated_on_premises" {
  description = <<-EOT
    Build a second VPC that plays the part of an on-premises data centre: one
    t4g.small running libreswan, configured from the REAL tunnel parameters that
    AWS generates for the VPN connection above.

    This is not a mock. The instance runs an actual IKEv2 daemon, negotiates
    with AWS's VPN endpoint, and the tunnel genuinely reaches UP -- you can watch
    the state change with 'aws ec2 describe-vpn-connections'.

    COST: about USD 0.021/hour for a t4g.small plus USD 0.005/hour for its
    Elastic IP address. Requires enable_site_to_site_vpn, because without a VPN
    connection there are no tunnel parameters to configure it from.

    Set false and bring your own on-premises device instead -- see the README
    for what you would need.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_simulated_on_premises || var.enable_site_to_site_vpn
    error_message = "enable_simulated_on_premises requires enable_site_to_site_vpn = true. The simulated router is configured from the tunnel parameters AWS generates for the VPN connection."
  }
}

variable "customer_gateway_ip" {
  description = <<-EOT
    Public IP address of your on-premises VPN device.

    Leave null when enable_simulated_on_premises is true -- an Elastic IP is
    allocated for the simulated router and used automatically.

    Set it to a real, routable public address when you are connecting genuine
    on-premises equipment. It must NOT be behind NAT that you do not control,
    and UDP 500 and 4500 must reach it.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.customer_gateway_ip == null || can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.customer_gateway_ip == null ? "203.0.113.1" : var.customer_gateway_ip))
    error_message = "customer_gateway_ip must be an IPv4 address, or null to use the simulated on-premises router's Elastic IP."
  }
}

variable "customer_gateway_bgp_asn" {
  description = "BGP ASN of the on-premises device. Must differ from the AWS side's ASN. 65000 is in the private range 64512-65534. Used for the customer gateway record even with static routing, because AWS requires the field."
  type        = number
  default     = 65000

  validation {
    condition     = var.customer_gateway_bgp_asn >= 1 && var.customer_gateway_bgp_asn <= 4294967294
    error_message = "customer_gateway_bgp_asn must be a valid BGP ASN. Use the private range 64512-65534 unless you own a public one."
  }
}

variable "use_bgp" {
  description = <<-EOT
    Use BGP for route exchange instead of static routes.

    BGP is what you want in production: routes are learned dynamically, both
    tunnels can be active at once, and failover happens in seconds without
    anyone editing a route table.

    The simulated on-premises router in this lab runs libreswan for IPsec but no
    BGP daemon, so it supports STATIC routing only. Set this true only when you
    are connecting real equipment that speaks BGP -- the README explains what
    changes.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.use_bgp || !var.enable_simulated_on_premises
    error_message = "use_bgp cannot be combined with enable_simulated_on_premises: the simulated router runs libreswan for IPsec but has no BGP daemon. Use static routing with the simulation, or bring a real BGP-capable device."
  }
}

variable "enable_transit_gateway_attachment" {
  description = <<-EOT
    Terminate the VPN on a Transit Gateway instead of on a virtual private
    gateway.

    This is what a real hybrid design does, because one VPN attachment on a
    Transit Gateway serves every attached VPC, whereas a virtual private gateway
    serves exactly one VPC and cannot be shared.

    COST: adds a Transit Gateway (free), a VPC attachment (~USD 0.05/hour) and
    a VPN attachment (~USD 0.05/hour) on top of the VPN connection itself.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_transit_gateway_attachment || var.acknowledge_costs
    error_message = "enable_transit_gateway_attachment requires acknowledge_costs = true. It adds about USD 0.10/hour in attachment charges."
  }
}

variable "enable_direct_connect_gateway" {
  description = <<-EOT
    Create an AWS Direct Connect gateway.

    A Direct Connect gateway with no attached virtual interfaces is FREE. It is
    a real, useful resource -- the thing that lets one Direct Connect connection
    reach VPCs in multiple Regions -- and creating it costs nothing.

    What this lab CANNOT create is a Direct Connect connection or a virtual
    interface, because those require a physical cross-connect at a colocation
    facility that AWS provisions with a partner. The README documents that
    architecture and the Terraform for it; nothing here pretends to build it.
  EOT
  type        = bool
  default     = false
}

variable "direct_connect_gateway_asn" {
  description = "Amazon-side BGP ASN for the Direct Connect gateway. Must differ from the ASNs used by the virtual private gateway and by your on-premises routers."
  type        = number
  default     = 64513

  validation {
    condition     = var.direct_connect_gateway_asn >= 64512 && var.direct_connect_gateway_asn <= 65534
    error_message = "direct_connect_gateway_asn should be in the private ASN range 64512-65534."
  }
}

variable "enable_test_instance" {
  description = "Launch a t4g.nano in the AWS VPC to ping across the tunnel. About USD 0.0053/hour plus USD 0.005/hour for its public IPv4 address."
  type        = bool
  default     = true
}

variable "on_premises_instance_type" {
  description = "Instance type for the simulated on-premises router. t4g.small rather than t4g.nano: libreswan and the kernel IPsec stack want more than 512 MB, and a router that swaps produces confusing intermittent tunnel drops."
  type        = string
  default     = "t4g.small"
}

variable "instance_type" {
  description = "EC2 instance type for the AWS-side test host."
  type        = string
  default     = "t4g.nano"
}

variable "instance_architecture" {
  description = "CPU architecture for the AMI lookup. Must match the instance types above."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.instance_architecture)
    error_message = "instance_architecture must be arm64 or x86_64."
  }
}

variable "additional_tags" {
  description = "Extra tags merged into the default tags applied to every resource."
  type        = map(string)
  default     = {}
}
