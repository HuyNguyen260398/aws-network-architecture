variable "aws_region" {
  description = "Region to deploy the lab into. Every Region has a different number of Availability Zones, so az_count is validated against what the Region actually offers."
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
  description = <<-EOT
    IPv4 CIDR block for the VPC.

    Plan this figure before you type it. A VPC CIDR cannot be changed after
    creation (you can only add secondary blocks), and two VPCs with overlapping
    ranges can never be peered or attached to the same Transit Gateway route
    table. Pick a slice of RFC 1918 space that no other network you might one
    day connect to is using.
  EOT
  type        = string
  default     = "10.10.0.0/16"

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
    error_message = "vpc_cidr must be a network address with all host bits zero. Use 10.10.0.0/16, not 10.10.0.1/16."
  }
}

variable "az_count" {
  description = "How many Availability Zones to spread subnets across. Two is enough to see multi-AZ behaviour; the lab creates one public and one private subnet per AZ."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 4
    error_message = "az_count must be between 1 and 4. Most Regions have three or four usable Availability Zones."
  }
}

variable "subnet_newbits" {
  description = "Bits to add to the VPC prefix when carving subnets. With a /16 VPC, 8 produces /24 subnets (251 usable addresses each, because AWS reserves 5). Larger numbers produce smaller subnets."
  type        = number
  default     = 8

  validation {
    condition     = var.subnet_newbits >= 1 && var.subnet_newbits <= 12
    error_message = "subnet_newbits must be between 1 and 12."
  }
}

variable "public_subnet_cidrs" {
  description = "Explicit public subnet CIDRs, one per Availability Zone. Leave empty to derive them from vpc_cidr and subnet_newbits, which is the recommended way to see how cidrsubnet() carves an address space."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.public_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry in public_subnet_cidrs must be a valid IPv4 CIDR block."
  }
}

variable "private_subnet_cidrs" {
  description = "Explicit private subnet CIDRs, one per Availability Zone. Leave empty to derive them from the upper half of the VPC range."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.private_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry in private_subnet_cidrs must be a valid IPv4 CIDR block."
  }
}

variable "enable_ipv6" {
  description = "Request an Amazon-provided /56 IPv6 block and give every subnet a /64 out of it. Free, and worth turning on once to see how differently IPv6 behaves: there is no NAT, no private range, and no address-space planning to do."
  type        = bool
  default     = false
}

variable "additional_tags" {
  description = "Extra tags merged into the default tags applied to every resource."
  type        = map(string)
  default     = {}
}
