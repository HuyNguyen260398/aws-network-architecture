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

variable "vpc_cidr" {
  description = "IPv4 CIDR block for the VPC. Uses a different /16 from every other lab so several labs can be deployed at once and later connected."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }

  validation {
    condition     = can(regex("^.*/(1[6-9]|2[0-8])$", var.vpc_cidr))
    error_message = "AWS accepts VPC CIDR blocks between /16 and /28 only."
  }

  validation {
    condition     = cidrhost(var.vpc_cidr, 0) == split("/", var.vpc_cidr)[0]
    error_message = "vpc_cidr must be a network address with all host bits zero."
  }
}

variable "az_count" {
  description = "Availability Zones to spread subnets across. Two is the minimum that demonstrates multi-AZ routing and cross-AZ data charges."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 4
    error_message = "az_count must be between 1 and 4."
  }
}

variable "subnet_newbits" {
  description = "Bits added to the VPC prefix when carving subnets. 8 on a /16 gives /24 subnets."
  type        = number
  default     = 8

  validation {
    condition     = var.subnet_newbits >= 1 && var.subnet_newbits <= 12
    error_message = "subnet_newbits must be between 1 and 12."
  }
}

# -----------------------------------------------------------------------------
# Cost gates
#
# Two keys are needed to create anything billed by the hour: the specific
# feature flag, and this global acknowledgement. The point is that you cannot
# enable an expensive resource without having read at least one sentence about
# what it costs.
# -----------------------------------------------------------------------------
variable "acknowledge_costs" {
  description = "Set to true to confirm you understand that the opt-in resources in this lab are billed by the hour and that you will destroy them when finished. Required before enable_nat_gateway can take effect."
  type        = bool
  default     = false
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Create a NAT gateway so private subnets can reach the internet outbound.

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
  description = "'single' places one NAT gateway in one Availability Zone (cheapest working option, but a zone failure removes outbound access for the whole VPC). 'per_az' places one per zone, which survives a zone failure and avoids cross-AZ data charges at N times the cost. Only used when enable_nat_gateway is true."
  type        = string
  default     = "single"

  validation {
    condition     = contains(["single", "per_az"], var.nat_gateway_mode)
    error_message = "nat_gateway_mode must be 'single' or 'per_az'. Use enable_nat_gateway = false for no NAT at all."
  }
}

variable "enable_ipv6" {
  description = "Add an Amazon-provided IPv6 /56 and give each subnet a /64. Free."
  type        = bool
  default     = false
}

variable "enable_egress_only_internet_gateway" {
  description = "Route ::/0 from private subnets to an egress-only internet gateway. This is the IPv6 equivalent of a NAT gateway -- outbound connections work, unsolicited inbound ones are blocked -- and unlike NAT it is completely FREE. Has no effect unless enable_ipv6 is also true."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Test instances
# -----------------------------------------------------------------------------
variable "enable_test_instances" {
  description = <<-EOT
    Launch one t4g.nano in a public subnet and one in a private subnet, both
    reachable through Session Manager (no SSH, no key pair).

    COST: about USD 0.0053/hour each, plus USD 0.005/hour for the public
    instance's public IPv4 address, plus about USD 0.77/month per 8 GB root
    volume. Roughly USD 0.016/hour -- USD 0.40 for a day of experimenting.

    Without these the lab is only route tables. With them you can actually test
    whether traffic flows.
  EOT
  type        = bool
  default     = true
}

variable "instance_type" {
  description = "EC2 instance type for the test hosts. Must be a Graviton (arm64) family unless you also change instance_architecture."
  type        = string
  default     = "t4g.nano"
}

variable "instance_architecture" {
  description = "CPU architecture for the AMI lookup. Must match instance_type."
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
