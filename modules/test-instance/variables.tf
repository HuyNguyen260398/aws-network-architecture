variable "name" {
  description = "Name for the instance and its associated resources. Appears in the Name tag and in the security group and IAM role names."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,54}$", var.name))
    error_message = "name must be 1-55 characters of letters, digits, dots, underscores and hyphens, starting alphanumerically. The limit leaves room for the suffixes this module appends."
  }
}

variable "vpc_id" {
  description = "VPC in which to create the security group. Must be the VPC that contains subnet_id."
  type        = string
}

variable "subnet_id" {
  description = "Subnet to launch the instance in. Whether the instance can reach AWS Systems Manager depends entirely on this subnet's routing: a public subnet with a public IP works, a private subnet needs either a NAT gateway or the three SSM interface endpoints."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. t4g.nano is the cheapest instance that runs the SSM agent comfortably (about USD 0.0053/hour in ap-southeast-1) and is Graviton, so it needs architecture = arm64."
  type        = string
  default     = "t4g.nano"

  validation {
    condition     = can(regex("^[a-z0-9]+[0-9][a-z]*\\.[a-z0-9]+$", var.instance_type))
    error_message = "instance_type must look like an EC2 instance type, for example t4g.nano or t3.micro."
  }
}

variable "architecture" {
  description = "CPU architecture of the AMI to select. Must match the instance type family: Graviton types (t4g, m7g, c7g, r7g) are arm64, everything else here is x86_64."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture must be arm64 or x86_64."
  }
}

variable "ami_id" {
  description = "Explicit AMI ID. Leave null to look up the newest Amazon Linux 2023 AMI for the chosen architecture, which is what keeps this repository portable across Regions -- an AMI ID is only valid in the Region it was published to."
  type        = string
  default     = null

  validation {
    condition     = var.ami_id == null || can(regex("^ami-[0-9a-f]{8,17}$", var.ami_id == null ? "ami-00000000" : var.ami_id))
    error_message = "ami_id must look like ami-0123456789abcdef0."
  }
}

variable "ami_name_filter" {
  description = "Name filter used to find the AMI when ami_id is null. Leave null for the current Amazon Linux 2023 pattern. Note this module queries EC2 DescribeImages rather than the /aws/service/ami-al2023 SSM public parameters, because some restricted IAM policies deny the /aws/ Parameter Store namespace."
  type        = string
  default     = null
}

variable "associate_public_ip_address" {
  description = "Give the instance a public IPv4 address. Needed only when the instance is in a public subnet and you want it to reach the SSM service without a NAT gateway or interface endpoints. Public IPv4 addresses are billed at roughly USD 0.005/hour."
  type        = bool
  default     = false
}

variable "enable_ssm" {
  description = "Create an IAM role granting AmazonSSMManagedInstanceCore, so the instance can be reached with Session Manager. This repository never opens SSH from the internet and never creates a key pair; Session Manager is how you get a shell."
  type        = bool
  default     = true
}

variable "additional_iam_policy_arns" {
  description = "Extra managed policy ARNs to attach to the instance role, keyed for stable resource addresses. Keep these minimal -- the point of the labs is networking, not IAM breadth."
  type        = map(string)
  default     = {}
}

variable "create_security_group" {
  description = "Create a security group for this instance. Set false and pass security_group_ids when several instances should share one group."
  type        = bool
  default     = true
}

variable "security_group_ids" {
  description = "Additional existing security groups to attach. Combined with the one this module creates when create_security_group is true."
  type        = list(string)
  default     = []
}

variable "ingress_rules" {
  description = <<-EOT
    Inbound rules for the security group this module creates. Empty by default:
    an instance you reach through Session Manager needs no inbound rules at all,
    because the SSM agent makes an OUTBOUND connection to the service.

    Each rule names exactly one source: cidr_ipv4, cidr_ipv6,
    referenced_security_group_id, or prefix_list_id. Map keys become resource
    addresses.
  EOT
  type = map(object({
    description                  = string
    ip_protocol                  = string
    from_port                    = optional(number)
    to_port                      = optional(number)
    cidr_ipv4                    = optional(string)
    cidr_ipv6                    = optional(string)
    referenced_security_group_id = optional(string)
    prefix_list_id               = optional(string)
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, r in var.ingress_rules :
      length(compact([
        try(r.cidr_ipv4, null), try(r.cidr_ipv6, null),
        try(r.referenced_security_group_id, null), try(r.prefix_list_id, null),
      ])) == 1
    ])
    error_message = "Each ingress rule must specify exactly one of cidr_ipv4, cidr_ipv6, referenced_security_group_id or prefix_list_id."
  }

  validation {
    condition = alltrue([
      for k, r in var.ingress_rules :
      r.ip_protocol == "-1" || (try(r.from_port, null) != null && try(r.to_port, null) != null)
    ])
    error_message = "Ingress rules must set from_port and to_port unless ip_protocol is \"-1\" (all protocols)."
  }

  validation {
    condition = alltrue([
      for k, r in var.ingress_rules :
      !(try(r.cidr_ipv4, null) == "0.0.0.0/0" && try(r.from_port, null) == 22)
    ])
    error_message = "Refusing to open SSH (port 22) to 0.0.0.0/0. This repository uses AWS Systems Manager Session Manager for shell access -- see modules/test-instance/README.md."
  }
}

variable "egress_rules" {
  description = "Outbound rules. The default allows all outbound traffic, which the SSM agent needs in order to reach the Systems Manager endpoints. Narrow it to the SSM endpoint prefix list if you want to practise egress filtering."
  type = map(object({
    description                  = string
    ip_protocol                  = string
    from_port                    = optional(number)
    to_port                      = optional(number)
    cidr_ipv4                    = optional(string)
    cidr_ipv6                    = optional(string)
    referenced_security_group_id = optional(string)
    prefix_list_id               = optional(string)
  }))
  default = {
    all_ipv4 = {
      description = "All outbound IPv4. Required for the SSM agent to reach Systems Manager."
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  validation {
    condition = alltrue([
      for k, r in var.egress_rules :
      length(compact([
        try(r.cidr_ipv4, null), try(r.cidr_ipv6, null),
        try(r.referenced_security_group_id, null), try(r.prefix_list_id, null),
      ])) == 1
    ])
    error_message = "Each egress rule must specify exactly one of cidr_ipv4, cidr_ipv6, referenced_security_group_id or prefix_list_id."
  }
}

variable "user_data" {
  description = "Cloud-init user data. Leave null for a bare Amazon Linux 2023 host. Never put a secret here: user data is readable from the instance metadata service by anything running on the instance."
  type        = string
  default     = null
}

variable "user_data_replace_on_change" {
  description = "Replace the instance when user_data changes. False means a user_data edit is applied only on the next launch, which is usually the surprising behaviour -- but replacing an instance changes its private IP, which breaks lab exercises that reference it."
  type        = bool
  default     = false
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB. Amazon Linux 2023 needs at least 8. gp3 storage is about USD 0.096 per GB-month in ap-southeast-1."
  type        = number
  default     = 8

  validation {
    condition     = var.root_volume_size_gb >= 8 && var.root_volume_size_gb <= 100
    error_message = "root_volume_size_gb must be between 8 and 100. Labs have no reason to need more."
  }
}

variable "enable_detailed_monitoring" {
  description = "Enable 1-minute CloudWatch metrics instead of the free 5-minute metrics. Costs roughly USD 2.10 per instance per month."
  type        = bool
  default     = false
}

variable "source_dest_check" {
  description = "Whether EC2 drops packets whose source or destination is not this instance. Must be false for an instance that forwards traffic -- a NAT instance, a software VPN endpoint, or a router. Leave true for ordinary hosts."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
