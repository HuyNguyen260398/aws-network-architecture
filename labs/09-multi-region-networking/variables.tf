variable "primary_region" {
  description = "Primary Region. All the labs in this repository default to ap-southeast-1."
  type        = string
  default     = "ap-southeast-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.primary_region))
    error_message = "primary_region must look like an AWS Region identifier."
  }
}

variable "secondary_region" {
  description = "Secondary Region for the inter-Region peering. ap-northeast-1 (Tokyo) is roughly 70 ms from Singapore, which is far enough for the latency to be visible in a ping and close enough that the tests are not tedious."
  type        = string
  default     = "ap-northeast-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.secondary_region))
    error_message = "secondary_region must look like an AWS Region identifier."
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

variable "primary_vpc_cidr" {
  description = "CIDR for the VPC in the primary Region."
  type        = string
  default     = "10.90.0.0/16"

  validation {
    condition     = can(cidrhost(var.primary_vpc_cidr, 0)) && cidrhost(var.primary_vpc_cidr, 0) == split("/", var.primary_vpc_cidr)[0]
    error_message = "primary_vpc_cidr must be a valid IPv4 network address with all host bits zero."
  }
}

variable "secondary_vpc_cidr" {
  description = "CIDR for the VPC in the secondary Region. Must not overlap the primary: inter-Region peering has exactly the same non-overlapping requirement as same-Region peering, and multi-Region designs are where address planning discipline pays off or fails."
  type        = string
  default     = "10.91.0.0/16"

  validation {
    condition     = can(cidrhost(var.secondary_vpc_cidr, 0)) && cidrhost(var.secondary_vpc_cidr, 0) == split("/", var.secondary_vpc_cidr)[0]
    error_message = "secondary_vpc_cidr must be a valid IPv4 network address with all host bits zero."
  }

  validation {
    condition = (
      sum([for i, o in split(".", split("/", var.secondary_vpc_cidr)[0]) : tonumber(o) * pow(256, 3 - i)]) >=
      sum([for i, o in split(".", split("/", var.primary_vpc_cidr)[0]) : tonumber(o) * pow(256, 3 - i)]) + pow(2, 32 - tonumber(split("/", var.primary_vpc_cidr)[1]))
      ||
      sum([for i, o in split(".", split("/", var.primary_vpc_cidr)[0]) : tonumber(o) * pow(256, 3 - i)]) >=
      sum([for i, o in split(".", split("/", var.secondary_vpc_cidr)[0]) : tonumber(o) * pow(256, 3 - i)]) + pow(2, 32 - tonumber(split("/", var.secondary_vpc_cidr)[1]))
    )
    error_message = "secondary_vpc_cidr overlaps primary_vpc_cidr. Inter-Region peering has the same non-overlapping requirement as same-Region peering."
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
  description = "Confirms you understand that the Transit Gateway option below is billed per attachment-hour. Required before enable_transit_gateway_peering can take effect."
  type        = bool
  default     = false
}

variable "enable_vpc_peering" {
  description = "Create the inter-Region VPC peering connection. Creating one is FREE; you pay only for data crossing it, at about USD 0.02/GB in each direction. On by default because it is the cheap, useful half of this lab."
  type        = bool
  default     = true
}

variable "enable_transit_gateway_peering" {
  description = <<-EOT
    Create a Transit Gateway in each Region, attach the local VPC to each, and
    peer the two gateways.

    COST: two VPC attachments plus two sides of a peering attachment, at about
    USD 0.05 per attachment-hour -- roughly USD 0.20/hour, USD 4.80/day,
    USD 146/month. Data across the peering is charged on top.

    Turn it on for half an hour if you want to see the topology, then off. The
    VPC peering above teaches most of the same routing lesson for nothing.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_transit_gateway_peering || var.acknowledge_costs
    error_message = "enable_transit_gateway_peering requires acknowledge_costs = true. Four attachments cost about USD 0.20/hour (USD 146/month)."
  }
}

variable "enable_route53_health_checks" {
  description = <<-EOT
    Create Route 53 health checks against the two Regions' test instances, which
    is the mechanism behind failover and latency-based DNS routing.

    COST: USD 0.50/month per health check against an AWS endpoint, USD 0.75
    against a non-AWS one. Two checks is about USD 1/month -- cheap, but it does
    require the instances to have public addresses, which this lab gives them.
  EOT
  type        = bool
  default     = false
}

variable "enable_test_instances" {
  description = "Launch one t4g.nano per Region so latency can actually be measured. About USD 0.021/hour for the pair including their public IPv4 addresses."
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

variable "additional_tags" {
  description = "Extra tags merged into the default tags applied to every resource."
  type        = map(string)
  default     = {}
}
