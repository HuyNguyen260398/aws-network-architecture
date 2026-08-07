variable "aws_region" {
  description = "Region to deploy the challenges into."
  type        = string
  default     = "ap-southeast-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must look like an AWS Region identifier."
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

variable "challenges" {
  description = <<-EOT
    Which broken scenarios to deploy. Enable ONE at a time the first few times:
    a single fault is a lesson, three at once is a mess.

      missing-route         A peering connection with a route on only one side.
      overlapping-cidr      Two VPCs that cannot be peered, and you work out why.
      security-group        A rule that references the wrong source.
      nacl-ephemeral        Outbound works; replies are silently dropped.
      broken-dns            A private hosted zone that resolves for nobody.
      endpoint-policy       An S3 gateway endpoint that denies the only bucket
                            you care about.
      missing-association   A gateway endpoint attached to no route table.
      asymmetric-routing    Two subnets, two route tables, one of them wrong.
      flow-log-rejects      Traffic dropped, with flow logs on so you can find it.

    Read HINTS.md only after you are stuck. SOLUTIONS.md gives the answer away.
  EOT
  type        = set(string)
  default     = ["missing-route"]

  validation {
    condition = alltrue([
      for c in var.challenges : contains([
        "missing-route",
        "overlapping-cidr",
        "security-group",
        "nacl-ephemeral",
        "broken-dns",
        "endpoint-policy",
        "missing-association",
        "asymmetric-routing",
        "flow-log-rejects",
      ], c)
    ])
    error_message = "Unknown challenge. Valid values: missing-route, overlapping-cidr, security-group, nacl-ephemeral, broken-dns, endpoint-policy, missing-association, asymmetric-routing, flow-log-rejects."
  }
}

variable "base_vpc_cidr" {
  description = "CIDR for the main challenge VPC, which holds the client and server instances used by most scenarios."
  type        = string
  default     = "10.100.0.0/16"

  validation {
    condition     = can(cidrhost(var.base_vpc_cidr, 0)) && cidrhost(var.base_vpc_cidr, 0) == split("/", var.base_vpc_cidr)[0]
    error_message = "base_vpc_cidr must be a valid IPv4 network address with all host bits zero."
  }
}

variable "peer_vpc_cidr" {
  description = "CIDR for the peer VPC used by the missing-route and asymmetric-routing challenges."
  type        = string
  default     = "10.101.0.0/16"

  validation {
    condition     = can(cidrhost(var.peer_vpc_cidr, 0)) && cidrhost(var.peer_vpc_cidr, 0) == split("/", var.peer_vpc_cidr)[0]
    error_message = "peer_vpc_cidr must be a valid IPv4 network address with all host bits zero."
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

variable "enable_test_instances" {
  description = "Launch the client and server hosts the challenges are diagnosed from. About USD 0.016/hour. Without them you can read configuration but cannot observe the symptoms, which is most of the exercise."
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

variable "flow_log_retention_days" {
  description = "CloudWatch Logs retention for the flow logs used by the flow-log-rejects challenge."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 3, 5, 7, 14], var.flow_log_retention_days)
    error_message = "Keep flow_log_retention_days short for a lab: 1, 3, 5, 7 or 14."
  }
}

variable "additional_tags" {
  description = "Extra tags merged into the default tags applied to every resource."
  type        = map(string)
  default     = {}
}
