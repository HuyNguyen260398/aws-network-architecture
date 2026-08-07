variable "aws_region" {
  description = "Region to deploy the lab into. All three VPCs live in the same Region; inter-Region peering is covered in lab 09."
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

variable "vpc_a_cidr" {
  description = "CIDR for VPC A, the hub of this lab's hub-and-spoke shape. A is peered with both B and C."
  type        = string
  default     = "10.40.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_a_cidr, 0)) && cidrhost(var.vpc_a_cidr, 0) == split("/", var.vpc_a_cidr)[0]
    error_message = "vpc_a_cidr must be a valid IPv4 network address with all host bits zero."
  }
}

variable "vpc_b_cidr" {
  description = <<-EOT
    CIDR for VPC B. Must not overlap VPC A.

    This is the constraint that makes address planning matter. AWS refuses to
    create a peering connection between VPCs with overlapping CIDRs, and there
    is no workaround -- no NAT, no translation, nothing. Two VPCs that both use
    10.0.0.0/16 can never be connected, and fixing it means rebuilding one of
    them.
  EOT
  type        = string
  default     = "10.41.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_b_cidr, 0)) && cidrhost(var.vpc_b_cidr, 0) == split("/", var.vpc_b_cidr)[0]
    error_message = "vpc_b_cidr must be a valid IPv4 network address with all host bits zero."
  }

  # Cross-variable validation, supported since Terraform 1.9. The arithmetic is
  # the same overlap test modules/vpc uses: two ranges overlap when each starts
  # before the other ends.
  validation {
    condition = (
      sum([for i, o in split(".", split("/", var.vpc_b_cidr)[0]) : tonumber(o) * pow(256, 3 - i)]) >=
      sum([for i, o in split(".", split("/", var.vpc_a_cidr)[0]) : tonumber(o) * pow(256, 3 - i)]) + pow(2, 32 - tonumber(split("/", var.vpc_a_cidr)[1]))
      ||
      sum([for i, o in split(".", split("/", var.vpc_a_cidr)[0]) : tonumber(o) * pow(256, 3 - i)]) >=
      sum([for i, o in split(".", split("/", var.vpc_b_cidr)[0]) : tonumber(o) * pow(256, 3 - i)]) + pow(2, 32 - tonumber(split("/", var.vpc_b_cidr)[1]))
    )
    error_message = "vpc_b_cidr overlaps vpc_a_cidr. Overlapping VPCs cannot be peered -- AWS rejects the peering connection outright, and there is no NAT or translation option to work around it."
  }
}

variable "vpc_c_cidr" {
  description = "CIDR for VPC C. Must not overlap A or B. C exists to demonstrate that peering is NOT transitive: it is peered with A, but cannot reach B through A."
  type        = string
  default     = "10.42.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_c_cidr, 0)) && cidrhost(var.vpc_c_cidr, 0) == split("/", var.vpc_c_cidr)[0]
    error_message = "vpc_c_cidr must be a valid IPv4 network address with all host bits zero."
  }

  validation {
    condition = (
      sum([for i, o in split(".", split("/", var.vpc_c_cidr)[0]) : tonumber(o) * pow(256, 3 - i)]) >=
      sum([for i, o in split(".", split("/", var.vpc_a_cidr)[0]) : tonumber(o) * pow(256, 3 - i)]) + pow(2, 32 - tonumber(split("/", var.vpc_a_cidr)[1]))
      ||
      sum([for i, o in split(".", split("/", var.vpc_a_cidr)[0]) : tonumber(o) * pow(256, 3 - i)]) >=
      sum([for i, o in split(".", split("/", var.vpc_c_cidr)[0]) : tonumber(o) * pow(256, 3 - i)]) + pow(2, 32 - tonumber(split("/", var.vpc_c_cidr)[1]))
    )
    error_message = "vpc_c_cidr overlaps vpc_a_cidr. Overlapping VPCs cannot be peered."
  }

  validation {
    condition = (
      sum([for i, o in split(".", split("/", var.vpc_c_cidr)[0]) : tonumber(o) * pow(256, 3 - i)]) >=
      sum([for i, o in split(".", split("/", var.vpc_b_cidr)[0]) : tonumber(o) * pow(256, 3 - i)]) + pow(2, 32 - tonumber(split("/", var.vpc_b_cidr)[1]))
      ||
      sum([for i, o in split(".", split("/", var.vpc_b_cidr)[0]) : tonumber(o) * pow(256, 3 - i)]) >=
      sum([for i, o in split(".", split("/", var.vpc_c_cidr)[0]) : tonumber(o) * pow(256, 3 - i)]) + pow(2, 32 - tonumber(split("/", var.vpc_c_cidr)[1]))
    )
    error_message = "vpc_c_cidr overlaps vpc_b_cidr."
  }
}

variable "subnet_newbits" {
  description = "Bits added to each VPC prefix when carving subnets. 8 on a /16 gives /24 subnets."
  type        = number
  default     = 8

  validation {
    condition     = var.subnet_newbits >= 1 && var.subnet_newbits <= 12
    error_message = "subnet_newbits must be between 1 and 12."
  }
}

variable "enable_vpc_c" {
  description = "Create the third VPC. C is what turns this from a peering demo into a lesson about transitive routing: it is peered with A, and still cannot reach B. Set false to halve the lab's cost."
  type        = bool
  default     = true
}

variable "enable_test_instances" {
  description = <<-EOT
    Launch one t4g.nano per VPC so you can actually ping across the peering
    connections. Without them this lab is three route tables you have to take on
    trust.

    COST: about USD 0.0053/hour per instance plus USD 0.005/hour per public IPv4
    address. Three VPCs is roughly USD 0.031/hour -- USD 0.75 for a day.

    The instances sit in public subnets with public IPs, which is the cheapest
    way to give them a Session Manager path in three separate VPCs. All the
    peering tests use PRIVATE addresses, so the public IP plays no part in what
    is being taught.
  EOT
  type        = bool
  default     = true
}

variable "instance_type" {
  description = "EC2 instance type for the test hosts."
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

variable "enable_b_to_c_peering" {
  description = <<-EOT
    Add a third peering connection, B to C, turning the hub-and-spoke into a
    full mesh.

    Leave this false first, confirm that B cannot reach C through A, and only
    then turn it on. The fix works -- and the number of connections needed grows
    as n(n-1)/2, so ten VPCs would need forty-five peering connections and
    ninety route table entries. That growth curve is the entire argument for
    Transit Gateway, which lab 05 covers.

    Peering connections are free to create; you pay only for data crossing them.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_b_to_c_peering || var.enable_vpc_c
    error_message = "enable_b_to_c_peering requires enable_vpc_c = true. There is no C to peer with otherwise."
  }
}

variable "additional_tags" {
  description = "Extra tags merged into the default tags applied to every resource."
  type        = map(string)
  default     = {}
}
