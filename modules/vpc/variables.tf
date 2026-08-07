variable "name" {
  description = "Name prefix for the VPC and every resource inside it. Appears in the Name tag, so keep it short and recognisable in the console."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,60}$", var.name))
    error_message = "name must be 1-61 characters of letters, digits, dots, underscores and hyphens, starting alphanumerically."
  }
}

variable "cidr_block" {
  description = "IPv4 CIDR block for the VPC. Choose from RFC 1918 space (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) and plan it so it never overlaps with another VPC or on-premises network you might one day connect to -- overlapping ranges cannot be peered, and re-addressing a live VPC means rebuilding it."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr_block, 0))
    error_message = "cidr_block must be a valid IPv4 CIDR, for example 10.0.0.0/16."
  }

  validation {
    condition     = can(regex("^.*/(1[6-9]|2[0-8])$", var.cidr_block))
    error_message = "AWS accepts VPC CIDR blocks between /16 and /28 only. /16 gives 65,536 addresses and is the usual choice for a lab."
  }

  validation {
    # A CIDR whose host bits are set (10.0.0.1/16) is a common and confusing
    # mistake: AWS silently normalises it, so Terraform then shows perpetual drift.
    condition     = can(cidrhost(var.cidr_block, 0)) && cidrhost(var.cidr_block, 0) == split("/", var.cidr_block)[0]
    error_message = "cidr_block must be a network address with all host bits zero. Use 10.0.0.0/16, not 10.0.0.1/16."
  }
}

variable "availability_zones" {
  description = "Explicit list of Availability Zone names to place subnets in. Leave empty to use every AZ in the Region that does not require opt-in, which is the portable choice: AZ names differ per account and hardcoding ap-southeast-1a breaks in someone else's account."
  type        = list(string)
  default     = []
}

variable "public_subnets" {
  description = <<-EOT
    Subnets that will be routed to an internet gateway. Map keys become resource
    addresses, so choose stable names -- renaming a key destroys and recreates
    the subnet.

    `az_index` selects from the resolved Availability Zone list.
    `map_public_ip_on_launch` decides whether instances launched here get a
    public IPv4 address automatically; it defaults to false because a public IP
    is chargeable and rarely what you want.
  EOT
  type = map(object({
    cidr_block              = string
    az_index                = number
    map_public_ip_on_launch = optional(bool, false)
    ipv6_prefix_index       = optional(number)
  }))
  default = {}

  validation {
    condition     = alltrue([for k, v in var.public_subnets : can(cidrhost(v.cidr_block, 0))])
    error_message = "Every public subnet cidr_block must be a valid IPv4 CIDR."
  }

  validation {
    condition     = alltrue([for k, v in var.public_subnets : can(regex("^.*/(1[6-9]|2[0-8])$", v.cidr_block))])
    error_message = "AWS accepts subnet CIDR blocks between /16 and /28 only. Remember AWS reserves 5 addresses in every subnet, so a /28 gives you 11 usable addresses."
  }

  validation {
    condition     = alltrue([for k, v in var.public_subnets : v.az_index >= 0])
    error_message = "az_index must be zero or greater."
  }
}

variable "private_subnets" {
  description = "Subnets with no route to an internet gateway. Whether they can reach the internet at all depends entirely on nat_gateway_mode -- with 'none' they are fully isolated, which is exactly what you want for a VPC-endpoint-only design."
  type = map(object({
    cidr_block        = string
    az_index          = number
    ipv6_prefix_index = optional(number)
  }))
  default = {}

  validation {
    condition     = alltrue([for k, v in var.private_subnets : can(cidrhost(v.cidr_block, 0))])
    error_message = "Every private subnet cidr_block must be a valid IPv4 CIDR."
  }

  validation {
    condition     = alltrue([for k, v in var.private_subnets : can(regex("^.*/(1[6-9]|2[0-8])$", v.cidr_block))])
    error_message = "AWS accepts subnet CIDR blocks between /16 and /28 only."
  }

  validation {
    condition     = alltrue([for k, v in var.private_subnets : v.az_index >= 0])
    error_message = "az_index must be zero or greater."
  }
}

variable "create_internet_gateway" {
  description = "Attach an internet gateway to the VPC. Internet gateways are free; you pay for the data that crosses them. Set to false for a fully private VPC, such as one that reaches AWS services only through VPC endpoints."
  type        = bool
  default     = true
}

variable "nat_gateway_mode" {
  description = <<-EOT
    How to give private subnets outbound internet access.

      none    No NAT gateway. Private subnets have no default route and cannot
              reach the internet at all. Free. This is the default.
      single  One NAT gateway in one Availability Zone, shared by every private
              subnet. Cheapest working option, but an AZ failure takes outbound
              access away from the whole VPC.
      per_az  One NAT gateway per Availability Zone that has a public subnet.
              Survives an AZ failure and avoids cross-AZ data charges, at
              N times the cost.

    A NAT gateway costs roughly USD 0.059 per hour in ap-southeast-1 (about
    USD 43 per month) PLUS about USD 0.059 per GB processed. It is the single
    most common source of surprise charges in a learning account.
  EOT
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "single", "per_az"], var.nat_gateway_mode)
    error_message = "nat_gateway_mode must be one of: none, single, per_az."
  }
}

variable "enable_ipv6" {
  description = "Request an Amazon-provided /56 IPv6 CIDR for the VPC and carve a /64 out of it for each subnet. IPv6 addresses on AWS are free and always public, which is why private IPv6 subnets need an egress-only internet gateway rather than NAT."
  type        = bool
  default     = false
}

variable "enable_egress_only_internet_gateway" {
  description = "Create an egress-only internet gateway and route ::/0 from private subnets to it. This is the IPv6 equivalent of a NAT gateway -- outbound connections work, inbound ones are blocked -- except that it is completely free. Requires enable_ipv6."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_egress_only_internet_gateway || var.enable_ipv6
    error_message = "enable_egress_only_internet_gateway requires enable_ipv6 = true."
  }
}

variable "enable_dns_support" {
  description = "Enable the Amazon-provided DNS resolver at the VPC base address plus two (for example 10.0.0.2). Turning this off breaks VPC endpoint private DNS, Route 53 private hosted zones, and SSM connectivity."
  type        = bool
  default     = true
}

variable "enable_dns_hostnames" {
  description = "Assign DNS hostnames to instances with public IPs, and enable the private DNS names that interface VPC endpoints depend on. Required for interface endpoint private DNS to work."
  type        = bool
  default     = true
}

variable "instance_tenancy" {
  description = "Tenancy for instances launched in this VPC. Leave as 'default'. Setting 'dedicated' forces every instance onto dedicated hardware at a large cost premium and cannot be changed back for existing instances."
  type        = string
  default     = "default"

  validation {
    condition     = contains(["default", "dedicated"], var.instance_tenancy)
    error_message = "instance_tenancy must be 'default' or 'dedicated'. Use 'default' unless you are deliberately studying dedicated tenancy -- it is expensive."
  }
}

variable "manage_default_security_group" {
  description = "Take ownership of the VPC's default security group and remove every rule from it. The AWS default allows unrestricted traffic between anything using it, which is a long-standing audit finding. Leaving this true is the secure choice."
  type        = bool
  default     = true
}

variable "manage_default_route_table" {
  description = "Take ownership of the VPC's main route table and keep it free of routes. Any subnet not explicitly associated with a route table falls back to this one, so keeping it empty means a forgotten association fails closed rather than silently gaining internet access."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource this module creates, merged with any provider default_tags."
  type        = map(string)
  default     = {}
}
