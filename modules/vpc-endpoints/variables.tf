variable "name" {
  description = "Name prefix for the endpoints and the security group this module creates."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,54}$", var.name))
    error_message = "name must be 1-55 characters of letters, digits, dots, underscores and hyphens."
  }
}

variable "vpc_id" {
  description = "VPC to create the endpoints in."
  type        = string
}

variable "gateway_endpoints" {
  description = <<-EOT
    Gateway endpoints to create, keyed by service short name. Only S3 and
    DynamoDB have gateway endpoints.

    Gateway endpoints are FREE -- no hourly charge, no data processing charge.
    They work by adding a prefix-list route to your route tables, so traffic to
    the service never leaves the AWS network and never touches a NAT gateway.
    If a private subnet's only internet-bound traffic is S3, a gateway endpoint
    replaces a NAT gateway entirely and saves about USD 43 a month.
  EOT
  type = map(object({
    policy = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for k, v in var.gateway_endpoints : contains(["s3", "dynamodb"], k)])
    error_message = "Gateway endpoints exist only for 's3' and 'dynamodb'. Every other AWS service uses an interface endpoint."
  }

  validation {
    condition     = alltrue([for k, v in var.gateway_endpoints : v.policy == null || can(jsondecode(v.policy))])
    error_message = "Each gateway endpoint policy must be valid JSON."
  }
}

variable "gateway_endpoint_route_table_ids" {
  description = "Route tables that should receive the gateway endpoint's prefix-list route. A gateway endpoint is invisible to a subnet whose route table is not listed here -- traffic silently falls through to the default route instead."
  type        = list(string)
  default     = []
}

variable "interface_endpoints" {
  description = <<-EOT
    Interface endpoints to create, keyed by service short name (for example
    "ssm", "ssmmessages", "ec2messages", "kms", "logs").

    COST WARNING: an interface endpoint is a set of elastic network interfaces,
    one per subnet you place it in, billed at roughly USD 0.011 per ENI-hour in
    ap-southeast-1 -- about USD 8 per ENI per month -- plus about USD 0.01/GB
    processed. Three endpoints across two subnets is six ENIs, roughly USD 48 a
    month. Place them in ONE subnet for a lab unless you are specifically
    studying high availability.

    Set private_dns_enabled to have the endpoint hijack the service's public DNS
    name inside the VPC, so unmodified SDK calls route through the endpoint.
    That requires enable_dns_support and enable_dns_hostnames on the VPC.
  EOT
  type = map(object({
    private_dns_enabled = optional(bool, true)
    subnet_ids          = optional(list(string))
    security_group_ids  = optional(list(string))
    policy              = optional(string)
    ip_address_type     = optional(string, "ipv4")
  }))
  default = {}

  validation {
    condition     = alltrue([for k, v in var.interface_endpoints : v.policy == null || can(jsondecode(v.policy))])
    error_message = "Each interface endpoint policy must be valid JSON."
  }

  validation {
    condition     = alltrue([for k, v in var.interface_endpoints : contains(["ipv4", "dualstack", "ipv6"], v.ip_address_type)])
    error_message = "ip_address_type must be ipv4, dualstack or ipv6."
  }
}

variable "interface_endpoint_subnet_ids" {
  description = "Default subnets for interface endpoints that do not name their own. One subnet is enough for a lab; each additional subnet adds an ENI and its hourly charge."
  type        = list(string)
  default     = []
}

variable "create_security_group" {
  description = "Create a security group for the interface endpoints that allows HTTPS from allowed_cidr_blocks. Set false to supply your own via security_group_ids on each endpoint."
  type        = bool
  default     = true
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks permitted to reach the interface endpoints on TCP 443. Normally the VPC CIDR. Interface endpoints speak HTTPS only, so nothing else needs to be open."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.allowed_cidr_blocks : can(cidrhost(c, 0))])
    error_message = "Every entry in allowed_cidr_blocks must be a valid IPv4 CIDR."
  }
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
