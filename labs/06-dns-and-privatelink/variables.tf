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

variable "provider_vpc_cidr" {
  description = "CIDR for the provider VPC, which hosts the service being published through PrivateLink."
  type        = string
  default     = "10.60.0.0/16"

  validation {
    condition     = can(cidrhost(var.provider_vpc_cidr, 0)) && cidrhost(var.provider_vpc_cidr, 0) == split("/", var.provider_vpc_cidr)[0]
    error_message = "provider_vpc_cidr must be a valid IPv4 network address with all host bits zero."
  }
}

variable "consumer_vpc_cidr" {
  description = <<-EOT
    CIDR for the consumer VPC, which reaches the service through an interface
    endpoint.

    Notice that PrivateLink does not care whether this overlaps the provider
    VPC: no routes are exchanged, so there is no address conflict to resolve.
    Try setting it to the same value as provider_vpc_cidr -- it works, and that
    is the single most underrated property of PrivateLink.
  EOT
  type        = string
  default     = "10.61.0.0/16"

  validation {
    condition     = can(cidrhost(var.consumer_vpc_cidr, 0)) && cidrhost(var.consumer_vpc_cidr, 0) == split("/", var.consumer_vpc_cidr)[0]
    error_message = "consumer_vpc_cidr must be a valid IPv4 network address with all host bits zero."
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
# DNS -- the free half of this lab
# -----------------------------------------------------------------------------
variable "private_zone_name" {
  description = "Name of the Route 53 private hosted zone. A private zone resolves only from VPCs it is associated with, and it costs USD 0.50/month regardless of query volume."
  type        = string
  default     = "lab06.internal"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.private_zone_name))
    error_message = "private_zone_name must be a valid lowercase DNS name with at least one dot, for example lab06.internal."
  }
}

variable "split_horizon_domain" {
  description = <<-EOT
    A domain that also exists publicly, published as a private hosted zone so
    that it resolves DIFFERENTLY inside the VPC. This is split-horizon DNS.

    The default, example.com, is reserved for documentation (RFC 2606) so no
    real service is affected. Inside the VPC it will resolve to a private
    address; from your laptop it resolves normally.

    Set to null to skip the demonstration.
  EOT
  type        = string
  default     = "example.com"

  validation {
    condition     = var.split_horizon_domain == null || can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.split_horizon_domain == null ? "example.com" : var.split_horizon_domain))
    error_message = "split_horizon_domain must be a valid lowercase DNS name, or null."
  }
}

# -----------------------------------------------------------------------------
# Cost gates
# -----------------------------------------------------------------------------
variable "acknowledge_costs" {
  description = "Confirms you understand that the PrivateLink and Route 53 Resolver options below are billed by the hour. Required before either can take effect."
  type        = bool
  default     = false
}

variable "enable_privatelink" {
  description = <<-EOT
    Publish a real service from the provider VPC through a Network Load Balancer
    and a VPC endpoint service, and consume it from the consumer VPC through an
    interface endpoint.

    COST in ap-southeast-1, roughly:
      Network Load Balancer   USD 0.0225/hour  + ~USD 0.006/LCU-hour
      Interface endpoint ENI  USD 0.011/hour
      Provider instance       USD 0.0053/hour
      Total                   ~USD 0.045/hour  (~USD 1.10/day)

    This is the half of the lab that actually demonstrates PrivateLink rather
    than describing it, and it is comparatively cheap. Off by default anyway.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_privatelink || var.acknowledge_costs
    error_message = "enable_privatelink requires acknowledge_costs = true. The Network Load Balancer and endpoint ENI cost about USD 0.045/hour together."
  }
}

variable "enable_resolver_inbound_endpoint" {
  description = <<-EOT
    Create a Route 53 Resolver INBOUND endpoint, which lets DNS queries from
    outside the VPC (normally from on-premises over VPN or Direct Connect) reach
    the VPC's private hosted zones.

    ###################################################################
    COST: USD 0.125 per ENI-hour, and AWS REQUIRES AT LEAST TWO ENIs in
    different Availability Zones. That is USD 0.25/hour -- USD 6/day,
    USD 180/month. This is the most expensive per-hour resource in the
    entire repository apart from Network Firewall.
    ###################################################################

    You can prove it works from inside the VPC by querying the endpoint's
    address directly, which is enough to understand it. Turn it on for twenty
    minutes (about eight cents), then off.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_resolver_inbound_endpoint || var.acknowledge_costs
    error_message = "enable_resolver_inbound_endpoint requires acknowledge_costs = true. A Resolver endpoint costs USD 0.25/hour (USD 180/month) because AWS mandates two ENIs."
  }
}

variable "enable_resolver_outbound_endpoint" {
  description = <<-EOT
    Create a Route 53 Resolver OUTBOUND endpoint plus a forwarding rule, so that
    queries for forward_domain are sent to your own DNS servers instead of being
    answered by AWS.

    COST: the same USD 0.25/hour as the inbound endpoint (two mandatory ENIs).

    This requires DNS servers that actually exist at forward_target_ips. There
    are none in this lab, so the rule is created and the forwarded queries will
    time out. That is honest rather than broken: the resources, the rule
    association and the failure mode are all real, and the README explains what
    a working deployment would point at.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_resolver_outbound_endpoint || var.acknowledge_costs
    error_message = "enable_resolver_outbound_endpoint requires acknowledge_costs = true. A Resolver endpoint costs USD 0.25/hour (USD 180/month)."
  }

  validation {
    condition     = !var.enable_resolver_outbound_endpoint || length(var.forward_target_ips) > 0
    error_message = "enable_resolver_outbound_endpoint requires at least one entry in forward_target_ips."
  }
}

variable "forward_domain" {
  description = "Domain whose queries the outbound Resolver endpoint forwards to forward_target_ips. In a real hybrid deployment this is your on-premises Active Directory domain."
  type        = string
  default     = "corp.internal"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.forward_domain))
    error_message = "forward_domain must be a valid lowercase DNS name."
  }
}

variable "forward_target_ips" {
  description = "IP addresses of the DNS servers that should answer queries for forward_domain. In a real deployment these are on-premises resolvers reachable over VPN or Direct Connect. The default is an RFC 5737 documentation address that will not answer, which is the point -- see the README."
  type        = list(string)
  default     = ["192.0.2.53"]

  validation {
    condition     = alltrue([for ip in var.forward_target_ips : can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", ip))])
    error_message = "Every entry in forward_target_ips must be an IPv4 address."
  }
}

# -----------------------------------------------------------------------------
# Test instances
# -----------------------------------------------------------------------------
variable "enable_test_instances" {
  description = "Launch a consumer instance (always) and, when PrivateLink is enabled, a provider instance running a small HTTP service. About USD 0.0053/hour each plus USD 0.005/hour per public IPv4 address."
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
