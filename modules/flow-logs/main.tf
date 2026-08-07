# =============================================================================
# VPC Flow Logs
#
# Flow logs record metadata about IP traffic -- source, destination, ports,
# bytes, and crucially whether the flow was ACCEPTed or REJECTed. They do NOT
# capture packet contents; use traffic mirroring for that.
#
# The ACCEPT/REJECT field is the reason this module matters for troubleshooting:
# a REJECT tells you a security group or network ACL dropped the packet, while
# NO flow log entry at all tells you the packet never arrived, which points at
# routing instead. Distinguishing those two cases by hand is otherwise guesswork.
# =============================================================================

data "aws_region" "current" {}

locals {
  to_cloudwatch = var.destination_type == "cloud-watch-logs"

  log_group_name = "/aws/vpc-flow-logs/${var.name}"

  tags = merge(var.tags, { Name = var.name })
}

# -----------------------------------------------------------------------------
# CloudWatch Logs destination
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "this" {
  count = local.to_cloudwatch ? 1 : 0

  name = local.log_group_name

  # 0 means "never expire" in CloudWatch Logs, and Terraform expresses that by
  # omitting the argument entirely.
  retention_in_days = var.log_retention_days == 0 ? null : var.log_retention_days
  kms_key_id        = var.kms_key_id

  tags = local.tags
}

resource "aws_iam_role" "this" {
  count = local.to_cloudwatch ? 1 : 0

  name_prefix = substr("${replace(var.name, "/[^a-zA-Z0-9-]/", "-")}-fl-", 0, 32)
  description = "Lets VPC Flow Logs publish ${var.name} records to CloudWatch Logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
    }]
  })

  tags = local.tags
}

# Scoped to this one log group rather than "Resource": "*". The delivery role is
# assumed by an AWS service, so a wildcard here would let flow logs from any
# resource in the account write anywhere in CloudWatch Logs.
resource "aws_iam_role_policy" "this" {
  count = local.to_cloudwatch ? 1 : 0

  name_prefix = "flow-logs-"
  role        = aws_iam_role.this[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = [
          aws_cloudwatch_log_group.this[0].arn,
          "${aws_cloudwatch_log_group.this[0].arn}:*",
        ]
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# The flow log itself
# -----------------------------------------------------------------------------
resource "aws_flow_log" "this" {
  traffic_type = var.traffic_type

  # Exactly one of these may be set. The API rejects a flow log that names both
  # a VPC and a subnet, so the unused ones are explicitly null.
  vpc_id    = var.resource_type == "VPC" ? var.resource_id : null
  subnet_id = var.resource_type == "Subnet" ? var.resource_id : null
  eni_id    = var.resource_type == "NetworkInterface" ? var.resource_id : null

  log_destination_type = var.destination_type
  log_destination      = local.to_cloudwatch ? aws_cloudwatch_log_group.this[0].arn : var.s3_bucket_arn
  iam_role_arn         = local.to_cloudwatch ? aws_iam_role.this[0].arn : null

  log_format               = var.log_format
  max_aggregation_interval = var.max_aggregation_interval

  tags = local.tags

  lifecycle {
    precondition {
      condition     = var.destination_type != "s3" || var.s3_bucket_arn != null
      error_message = "destination_type is 's3' but s3_bucket_arn is null. Flow logs need somewhere to be delivered."
    }

    precondition {
      condition     = var.destination_type != "cloud-watch-logs" || var.s3_bucket_arn == null
      error_message = "s3_bucket_arn was supplied but destination_type is 'cloud-watch-logs'. Set destination_type = \"s3\" if you want S3 delivery."
    }
  }
}
