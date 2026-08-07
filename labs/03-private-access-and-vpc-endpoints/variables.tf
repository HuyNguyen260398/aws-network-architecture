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
  description = "IPv4 CIDR block for the VPC. This lab creates a VPC with NO internet gateway at all, to prove that AWS services can be reached without one."
  type        = string
  default     = "10.30.0.0/16"

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
  description = "Availability Zones to spread private subnets across. Interface endpoints are placed in the FIRST zone only, because each additional zone adds a billed ENI."
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
# -----------------------------------------------------------------------------
variable "acknowledge_costs" {
  description = "Confirms you understand that interface endpoints are billed per ENI-hour. Required before enable_interface_endpoints can take effect."
  type        = bool
  default     = false
}

variable "enable_s3_gateway_endpoint" {
  description = "Create an S3 gateway endpoint. FREE -- no hourly charge, no data processing charge. It works by adding a managed prefix list route to the private route tables. Leave this on; it is the cheap half of the lab."
  type        = bool
  default     = true
}

variable "enable_interface_endpoints" {
  description = <<-EOT
    Create interface endpoints for ssm, ssmmessages and ec2messages, so the
    private instance can be reached with Session Manager despite having no
    internet access at all.

    COST: roughly USD 0.011 per ENI-hour in ap-southeast-1 (about USD 8 per ENI
    per month) plus about USD 0.01 per GB processed. Three endpoints in one
    subnet is three ENIs -- about USD 0.033/hour, or USD 24/month.

    Still cheaper than the USD 43/month NAT gateway it replaces, and the traffic
    never touches the public internet. Off by default so that the free half of
    this lab costs nothing.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_interface_endpoints || var.acknowledge_costs
    error_message = "enable_interface_endpoints requires acknowledge_costs = true. Three interface endpoints cost about USD 24/month."
  }
}

variable "interface_endpoints" {
  description = "Which interface endpoint services to create when enable_interface_endpoints is true. The three Session Manager services are the default; ALL THREE are required for Session Manager to work, and omitting ec2messages is a classic mistake."
  type        = list(string)
  default     = ["ssm", "ssmmessages", "ec2messages"]

  validation {
    condition     = length(var.interface_endpoints) > 0
    error_message = "interface_endpoints must not be empty when interface endpoints are enabled. Set enable_interface_endpoints = false instead."
  }
}

variable "additional_s3_endpoint_bucket_arns" {
  description = "Extra bucket ARNs to allow through the S3 endpoint policy. Used by the README's exercise on discovering which AWS-owned buckets a workload actually depends on -- the Amazon Linux package repositories being the usual surprise. Ignored when restrict_s3_endpoint_to_lab_bucket is false."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.additional_s3_endpoint_bucket_arns : can(regex("^arn:aws[a-z-]*:s3:::[a-z0-9.-]+$", a))])
    error_message = "Each entry must be a bare S3 bucket ARN with no trailing slash or object path, for example arn:aws:s3:::example-bucket."
  }
}

variable "restrict_s3_endpoint_to_lab_bucket" {
  description = "Attach an endpoint policy that allows the S3 gateway endpoint to reach only this lab's bucket. This is the mechanism that stops data being copied out of your VPC into an S3 bucket in someone else's account. Turn it off to see the difference."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Test resources
# -----------------------------------------------------------------------------
variable "enable_test_instance" {
  description = "Launch a t4g.nano in a private subnet (~USD 0.0053/hour). Without it you can inspect routes and DNS but cannot run the connectivity tests, which are the point of the lab."
  type        = bool
  default     = true
}

variable "instance_type" {
  description = "EC2 instance type for the test host."
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
