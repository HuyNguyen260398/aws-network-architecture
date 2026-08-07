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

# -----------------------------------------------------------------------------
# THE COST GATE
#
# This lab is the most expensive in the repository. Nothing chargeable is
# created unless BOTH flags below are true.
# -----------------------------------------------------------------------------
variable "acknowledge_costs" {
  description = "Confirms you understand that a Transit Gateway attachment is billed per hour whether or not traffic flows. Required before enable_transit_gateway can take effect."
  type        = bool
  default     = false
}

variable "enable_transit_gateway" {
  description = <<-EOT
    Create the Transit Gateway, its attachments and its route tables.

    COST: about USD 0.05 per attachment-hour in ap-southeast-1, plus about
    USD 0.02 per GB processed. Three attachments is roughly USD 0.15/hour --
    USD 3.60 a day, USD 110 a month. The Transit Gateway itself is free; the
    ATTACHMENTS are what you pay for.

    With this false the lab still creates the three spoke VPCs (which are free)
    so you can read the topology, inspect route tables and follow the
    documentation. Nothing connects them.

    Turn it on, do the exercises in one sitting, then destroy. An hour of this
    lab costs about fifteen cents.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_transit_gateway || var.acknowledge_costs
    error_message = "enable_transit_gateway requires acknowledge_costs = true. Three Transit Gateway attachments cost about USD 0.15/hour (USD 110/month)."
  }
}

# -----------------------------------------------------------------------------
# Addressing
# -----------------------------------------------------------------------------
variable "prod_vpc_cidr" {
  description = "CIDR for the production spoke VPC."
  type        = string
  default     = "10.50.0.0/16"

  validation {
    condition     = can(cidrhost(var.prod_vpc_cidr, 0)) && cidrhost(var.prod_vpc_cidr, 0) == split("/", var.prod_vpc_cidr)[0]
    error_message = "prod_vpc_cidr must be a valid IPv4 network address with all host bits zero."
  }
}

variable "dev_vpc_cidr" {
  description = "CIDR for the development spoke VPC. Must not overlap the others -- a Transit Gateway route table cannot hold two routes for the same prefix pointing at different attachments."
  type        = string
  default     = "10.51.0.0/16"

  validation {
    condition     = can(cidrhost(var.dev_vpc_cidr, 0)) && cidrhost(var.dev_vpc_cidr, 0) == split("/", var.dev_vpc_cidr)[0]
    error_message = "dev_vpc_cidr must be a valid IPv4 network address with all host bits zero."
  }
}

variable "shared_vpc_cidr" {
  description = "CIDR for the shared-services spoke VPC. Both prod and dev may reach this one; that asymmetry is the segmentation lesson."
  type        = string
  default     = "10.52.0.0/16"

  validation {
    condition     = can(cidrhost(var.shared_vpc_cidr, 0)) && cidrhost(var.shared_vpc_cidr, 0) == split("/", var.shared_vpc_cidr)[0]
    error_message = "shared_vpc_cidr must be a valid IPv4 network address with all host bits zero."
  }
}

variable "supernet_cidr" {
  description = <<-EOT
    A summary route that covers all three spoke CIDRs. Each VPC's route table
    gets ONE entry for this prefix pointing at the Transit Gateway, instead of
    one entry per remote VPC.

    Summarising at the VPC edge is what keeps a Transit Gateway design
    manageable: adding a fourth VPC inside the supernet requires no change to
    any existing VPC route table. Whether traffic is actually permitted is then
    decided entirely by the Transit Gateway route tables, in one place.
  EOT
  type        = string
  default     = "10.48.0.0/12"

  validation {
    condition     = can(cidrhost(var.supernet_cidr, 0)) && cidrhost(var.supernet_cidr, 0) == split("/", var.supernet_cidr)[0]
    error_message = "supernet_cidr must be a valid IPv4 network address with all host bits zero."
  }
}

variable "subnet_newbits" {
  description = "Bits added to each VPC prefix for the workload subnet. 8 on a /16 gives /24."
  type        = number
  default     = 8

  validation {
    condition     = var.subnet_newbits >= 1 && var.subnet_newbits <= 12
    error_message = "subnet_newbits must be between 1 and 12."
  }
}

variable "blackhole_cidr" {
  description = "A prefix to install as a blackhole route in the spoke Transit Gateway route table. Traffic to it is silently discarded at the Transit Gateway. This is how you quarantine a compromised range, or deliberately drop traffic to a decommissioned network, without touching a single VPC route table. Defaults to a documentation range (RFC 5737) so nothing real is affected."
  type        = string
  default     = "192.0.2.0/24"

  validation {
    condition     = can(cidrhost(var.blackhole_cidr, 0))
    error_message = "blackhole_cidr must be a valid IPv4 CIDR block."
  }
}

variable "enable_test_instances" {
  description = "Launch one t4g.nano per VPC so the segmentation rules can be tested with ping. About USD 0.0053/hour each plus USD 0.005/hour per public IPv4 address -- roughly USD 0.031/hour for three, which is small next to the attachment charges."
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

variable "allow_dev_to_prod" {
  description = "Add a propagation that lets dev reach prod, collapsing the segmentation. Left false. Turning it on and watching a single Terraform change open a path between two isolated environments is the clearest demonstration of why Transit Gateway route tables are a security control, not just a routing detail."
  type        = bool
  default     = false
}

variable "additional_tags" {
  description = "Extra tags merged into the default tags applied to every resource."
  type        = map(string)
  default     = {}
}
