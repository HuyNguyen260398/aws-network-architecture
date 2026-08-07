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
  description = "IPv4 CIDR block for the VPC."
  type        = string
  default     = "10.80.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && cidrhost(var.vpc_cidr, 0) == split("/", var.vpc_cidr)[0]
    error_message = "vpc_cidr must be a valid IPv4 network address with all host bits zero."
  }

  validation {
    condition     = can(regex("^.*/(1[6-9]|2[0-4])$", var.vpc_cidr))
    error_message = "vpc_cidr must be between /16 and /24 so there is room for the subnets this lab carves."
  }
}

variable "subnet_newbits" {
  description = "Bits added to the VPC prefix when carving subnets."
  type        = number
  default     = 8

  validation {
    condition     = var.subnet_newbits >= 1 && var.subnet_newbits <= 12
    error_message = "subnet_newbits must be between 1 and 12."
  }
}

# -----------------------------------------------------------------------------
# Observability -- cheap, on by default
# -----------------------------------------------------------------------------
variable "enable_flow_logs" {
  description = "Capture VPC Flow Logs to CloudWatch Logs. A quiet lab VPC generates a few megabytes a day, so this costs cents. It is on by default because the ACCEPT/REJECT field is what makes the rest of this lab legible."
  type        = bool
  default     = true
}

variable "flow_log_traffic_type" {
  description = "Which flows to record: ACCEPT, REJECT or ALL. ALL is right for this lab because you need to see both the traffic that worked and the traffic that did not. REJECT alone is the cheap production setting for security monitoring."
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.flow_log_traffic_type)
    error_message = "flow_log_traffic_type must be ACCEPT, REJECT or ALL."
  }
}

variable "flow_log_retention_days" {
  description = "CloudWatch Logs retention for the flow logs. One day by default: a lab log group left at 'never expire' keeps billing for storage long after the VPC is gone."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30], var.flow_log_retention_days)
    error_message = "For a lab, keep flow_log_retention_days short: 1, 3, 5, 7, 14 or 30."
  }
}

variable "flow_log_aggregation_interval" {
  description = "Seconds before a flow record is published: 60 or 600. Use 60 while actively troubleshooting so records appear within about a minute; 600 is cheaper."
  type        = number
  default     = 60

  validation {
    condition     = contains([60, 600], var.flow_log_aggregation_interval)
    error_message = "flow_log_aggregation_interval must be 60 or 600."
  }
}

variable "run_reachability_analysis" {
  description = "Run AWS Reachability Analyzer against the paths this lab defines. Creating a path is free; each ANALYSIS costs USD 0.10. Two analyses is twenty cents, and being shown the exact blocking component by name is worth considerably more than that."
  type        = bool
  default     = true
}

variable "enable_cloudtrail" {
  description = "Create a CloudTrail trail recording management events for this account, so you can see who changed a security group and when. The first copy of management events in an account is free; you pay only S3 storage, which is pennies for a lab. Off by default because a trail is account-wide, not lab-scoped, and you may already have one."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# The demonstration NACL
# -----------------------------------------------------------------------------
variable "nacl_block_port" {
  description = "TCP port that the demonstration network ACL denies inbound to the private subnet. 8080 by default, which is the port the test service listens on -- so you can watch a REJECT appear in the flow logs for traffic a security group would have allowed."
  type        = number
  default     = 8080

  validation {
    condition     = var.nacl_block_port > 0 && var.nacl_block_port < 65536
    error_message = "nacl_block_port must be a valid TCP port."
  }
}

variable "enable_nacl_block" {
  description = "Apply the deny rule. Turn it off, apply, and compare the flow logs: the same connection that produced a REJECT now produces an ACCEPT, with nothing else changed."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# AWS Network Firewall -- the expensive option
# -----------------------------------------------------------------------------
variable "acknowledge_costs" {
  description = "Confirms you understand that AWS Network Firewall is billed per endpoint-hour and per gigabyte. Required before enable_network_firewall can take effect."
  type        = bool
  default     = false
}

variable "enable_network_firewall" {
  description = <<-EOT
    Deploy AWS Network Firewall and route east-west traffic between two subnets
    through it.

    ###################################################################
    COST: about USD 0.395 per firewall-endpoint-hour in ap-southeast-1,
    plus about USD 0.065 per GB inspected. That is USD 9.48 A DAY and
    roughly USD 288 A MONTH for a single endpoint.

    THIS IS THE MOST EXPENSIVE RESOURCE IN THIS REPOSITORY.
    ###################################################################

    This lab inspects traffic between two subnets in the same VPC rather than
    egress to the internet, deliberately: it demonstrates the same inspection
    routing without also requiring a NAT gateway.

    Turn it on for thirty minutes (about twenty cents), watch a stateful rule
    drop traffic, read the alert logs, and turn it off.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_network_firewall || var.acknowledge_costs
    error_message = "enable_network_firewall requires acknowledge_costs = true. A firewall endpoint costs about USD 0.395/hour -- USD 288/month."
  }
}

variable "firewall_blocked_port" {
  description = "TCP port the Network Firewall stateful rule drops between the two inspected subnets. Used only when enable_network_firewall is true."
  type        = number
  default     = 8080

  validation {
    condition     = var.firewall_blocked_port > 0 && var.firewall_blocked_port < 65536
    error_message = "firewall_blocked_port must be a valid TCP port."
  }
}

# -----------------------------------------------------------------------------
# Test instances
# -----------------------------------------------------------------------------
variable "enable_test_instances" {
  description = "Launch a client in the public subnet and a server in the private subnet. About USD 0.016/hour together. Without them there is no traffic to observe and no path to analyse."
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
