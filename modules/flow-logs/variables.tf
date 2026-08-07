variable "name" {
  description = "Name prefix for the flow log, its log group, and its IAM role."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9._/-]{0,48}$", var.name))
    error_message = "name must be 1-49 characters of letters, digits, dots, underscores, slashes and hyphens."
  }
}

variable "resource_type" {
  description = <<-EOT
    What to capture traffic for.

      VPC              Every network interface in the VPC, including ones
                       created later. The usual choice.
      Subnet           Every interface in one subnet.
      NetworkInterface A single ENI. Use this to keep volume (and cost) down
                       when you only care about one instance.
  EOT
  type        = string
  default     = "VPC"

  validation {
    condition     = contains(["VPC", "Subnet", "NetworkInterface"], var.resource_type)
    error_message = "resource_type must be VPC, Subnet or NetworkInterface."
  }
}

variable "resource_id" {
  description = "ID of the VPC, subnet, or network interface to capture traffic for. Must match resource_type."
  type        = string
}

variable "traffic_type" {
  description = "Which flows to record. REJECT alone is the cheapest useful setting for a security investigation, because it captures exactly the traffic a security group or NACL dropped. ALL is what you want when debugging a path that should work but does not."
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.traffic_type)
    error_message = "traffic_type must be ACCEPT, REJECT or ALL."
  }
}

variable "destination_type" {
  description = <<-EOT
    Where records are delivered.

      cloud-watch-logs  Queryable within a minute or two with Logs Insights.
                        Roughly USD 0.50/GB ingested plus storage. Best for labs.
      s3                Roughly USD 0.25/GB delivered plus S3 storage. Cheaper at
                        volume, and the right answer for long-term retention, but
                        you need Athena to query it.
  EOT
  type        = string
  default     = "cloud-watch-logs"

  validation {
    condition     = contains(["cloud-watch-logs", "s3"], var.destination_type)
    error_message = "destination_type must be cloud-watch-logs or s3."
  }
}

variable "s3_bucket_arn" {
  description = "ARN of the destination bucket when destination_type is s3. Optionally add a prefix, for example arn:aws:s3:::my-bucket/flow-logs/."
  type        = string
  default     = null

  validation {
    condition     = var.s3_bucket_arn == null || can(regex("^arn:aws[a-z-]*:s3:::", var.s3_bucket_arn == null ? "arn:aws:s3:::x" : var.s3_bucket_arn))
    error_message = "s3_bucket_arn must be an S3 bucket ARN, for example arn:aws:s3:::my-bucket."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention. Defaults to 1 day, deliberately: a lab log group left at 'never expire' keeps billing you for storage long after the VPC is gone. Set 0 for never expire."
  type        = number
  default     = 1

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of the values CloudWatch Logs accepts: 0 (never expire), 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288 or 3653."
  }
}

variable "kms_key_id" {
  description = "Customer-managed KMS key ARN for the CloudWatch log group. Null uses the AWS-owned key, which still encrypts the data at rest and costs nothing. A customer-managed key costs about USD 1/month; use one when you need auditable key access."
  type        = string
  default     = null
}

variable "log_format" {
  description = <<-EOT
    Custom flow log record format, as a space-separated list of $${field} tokens.
    Null uses the AWS default (version 2) fields.

    Adding fields such as $${pkt-srcaddr}, $${pkt-dstaddr} and $${flow-direction}
    is what lets you tell the ORIGINAL source of a packet from the address of the
    NAT gateway or load balancer that relayed it -- the single most useful
    addition when debugging traffic that has been translated.
  EOT
  type        = string
  default     = null
}

variable "max_aggregation_interval" {
  description = "Seconds over which flows are aggregated before a record is published: 60 or 600. 60 gives faster feedback during a lab at the cost of more records; 600 is the cheaper default."
  type        = number
  default     = 600

  validation {
    condition     = contains([60, 600], var.max_aggregation_interval)
    error_message = "max_aggregation_interval must be 60 or 600 seconds."
  }
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
