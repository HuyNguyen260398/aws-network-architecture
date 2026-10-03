# =============================================================================
# Seeing what the network does.
#
# Every lab so far ended with "curl it and see". That stops working the moment
# something is broken, because a dropped packet looks the same from the client
# whatever dropped it. This file adds the three tools that tell you:
#
#   VPC Flow Logs           what traffic was ACCEPTed or REJECTed, per interface
#   Reachability Analyzer   whether a path exists, and which component blocks it
#   CloudTrail              who changed the network, and when
#
# and one deliberate fault to find with them.
# =============================================================================

data "aws_caller_identity" "current" {}

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

variable "enable_nacl_block" {
  description = "Inject a fault: add a DENY rule to the data-tier network ACL, numbered below the allow rules, that drops the database port. The shop's payment service then fails to reach the database, and nothing reports why. Find it with flow logs and Reachability Analyzer, then turn it off."
  type        = bool
  default     = false
}

variable "run_reachability_analysis" {
  description = "Run AWS Reachability Analyzer against the paths this lab defines. Creating a path is free; each ANALYSIS costs USD 0.10 and is re-run whenever you change this to true. Being shown the exact blocking component by name is worth considerably more than that."
  type        = bool
  default     = false
}

variable "enable_cloudtrail" {
  description = "Create a CloudTrail trail recording management events for this account, so you can see who changed a security group and when. The first copy of management events in an account is free; you pay only S3 storage, which is pennies for a lab. Off by default because a trail is account-wide, not lab-scoped, and you may already have one."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Flow logs for the whole shop VPC
# -----------------------------------------------------------------------------
module "flow_logs" {
  count  = var.enable_flow_logs ? 1 : 0
  source = "../../modules/flow-logs"

  name          = local.name_prefix
  resource_type = "VPC"
  resource_id   = module.vpc.vpc_id

  traffic_type             = var.flow_log_traffic_type
  destination_type         = "cloud-watch-logs"
  log_retention_days       = var.flow_log_retention_days
  max_aggregation_interval = var.flow_log_aggregation_interval

  # The default format omits the fields that matter most once NAT, load
  # balancers and containers are involved. pkt-srcaddr / pkt-dstaddr are the
  # ORIGINAL addresses of the packet; srcaddr / dstaddr are those of the
  # interface that logged it. They differ exactly where translation happened.
  log_format = join(" ", [
    "$${version}", "$${vpc-id}", "$${subnet-id}", "$${instance-id}", "$${interface-id}",
    "$${srcaddr}", "$${dstaddr}", "$${srcport}", "$${dstport}", "$${protocol}",
    "$${packets}", "$${bytes}", "$${start}", "$${end}",
    "$${action}", "$${log-status}",
    "$${pkt-srcaddr}", "$${pkt-dstaddr}", "$${flow-direction}", "$${traffic-path}",
  ])

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# The fault
# -----------------------------------------------------------------------------

# Rule 90 is evaluated before the allow rules at 100 and 101, and evaluation
# stops at the first match. The security groups still permit the traffic, the
# route still exists, and the database is still listening.
resource "aws_network_acl_rule" "data_in_deny_database" {
  count = var.enable_nacl_block ? 1 : 0

  network_acl_id = aws_network_acl.data.id
  rule_number    = 90
  egress         = false
  protocol       = "tcp"
  rule_action    = "deny"
  cidr_block     = var.vpc_cidr
  from_port      = local.database_port
  to_port        = local.database_port
}

# -----------------------------------------------------------------------------
# Reachability Analyzer
#
# A path is a question: can this source reach this destination on this port?
# An analysis answers it by reading the configuration -- route tables,
# security groups, network ACLs -- without sending a single packet.
# -----------------------------------------------------------------------------
locals {
  reachability_paths = {
    # Should be reachable. Is not, while enable_nacl_block is true.
    app_to_db = {
      source      = module.app.primary_network_interface_id
      destination = module.db.primary_network_interface_id
      port        = local.database_port
    }
    # Should NEVER be reachable: the web tier has no business with the
    # database, and the database security group says so.
    web_to_db = {
      source      = module.web.primary_network_interface_id
      destination = module.db.primary_network_interface_id
      port        = local.database_port
    }
  }
}

resource "aws_ec2_network_insights_path" "shop" {
  for_each = local.reachability_paths

  source           = each.value.source
  destination      = each.value.destination
  protocol         = "tcp"
  destination_port = each.value.port

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-${replace(each.key, "_", "-")}" })
}

resource "aws_ec2_network_insights_analysis" "shop" {
  for_each = var.run_reachability_analysis ? local.reachability_paths : {}

  network_insights_path_id = aws_ec2_network_insights_path.shop[each.key].id
  wait_for_completion      = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-${replace(each.key, "_", "-")}" })
}

# =============================================================================
# CloudTrail -- opt-in
#
# Not a networking service, but the answer to "who opened that security group?".
# Every VPC, route table, security group and NACL change is an EC2 API call and
# appears here.
# =============================================================================
resource "random_id" "trail_suffix" {
  count = var.enable_cloudtrail ? 1 : 0

  byte_length = 4
}

resource "aws_s3_bucket" "trail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket        = "${local.name_prefix}-trail-${random_id.trail_suffix[0].hex}"
  force_destroy = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-trail" })
}

resource "aws_s3_bucket_public_access_block" "trail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.trail[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.trail[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "trail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.trail[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

# CloudTrail writes as a service principal, so the bucket policy -- not an IAM
# role -- is what authorises it. The aws:SourceArn condition stops another
# account's trail from writing into your bucket, which is the "confused deputy"
# problem AWS documents for exactly this pattern.
resource "aws_s3_bucket_policy" "trail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.trail[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.trail[0].arn, "${aws_s3_bucket.trail[0].arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.trail[0].arn
        Condition = {
          StringEquals = {
            "aws:SourceArn" = "arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/${local.name_prefix}-trail"
          }
        }
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.trail[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = "arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/${local.name_prefix}-trail"
          }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.trail]
}

resource "aws_cloudtrail" "this" {
  count = var.enable_cloudtrail ? 1 : 0

  name           = "${local.name_prefix}-trail"
  s3_bucket_name = aws_s3_bucket.trail[0].id

  # Management events only. Data events (S3 object reads, Lambda invocations)
  # are charged per event and can be very expensive in a busy account.
  include_global_service_events = true
  is_multi_region_trail         = false
  enable_log_file_validation    = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-trail" })

  depends_on = [aws_s3_bucket_policy.trail]
}


output "flow_log_group_name" {
  description = "CloudWatch Logs group receiving the VPC flow logs, or null when disabled."
  value       = one(module.flow_logs[*].log_group_name)
}

output "flow_log_tail_command" {
  description = "Streams new flow log records to your terminal. Run it in a second window while you generate traffic."
  value       = one(module.flow_logs[*].tail_command)
}

output "flow_log_queries" {
  description = "CloudWatch Logs Insights queries for the custom log format. Paste them into the Logs Insights console against the log group above."
  value = var.enable_flow_logs ? {
    rejected_flows = join("\n", [
      "fields @timestamp, srcAddr, dstAddr, srcPort, dstPort, protocol, action",
      "| filter action = \"REJECT\"",
      "| sort @timestamp desc",
      "| limit 50",
    ])

    traffic_to_the_database = join("\n", [
      "fields @timestamp, srcAddr, dstAddr, dstPort, action, flowDirection",
      "| filter dstPort = ${local.database_port}",
      "| sort @timestamp desc",
      "| limit 50",
    ])

    top_talkers = join("\n", [
      "stats sum(bytes) as totalBytes by srcAddr, dstAddr",
      "| sort totalBytes desc",
      "| limit 20",
    ])

    # Rows where the interface address and the packet address differ: NAT
    # gateway, load balancer and container traffic.
    original_vs_translated = join("\n", [
      "fields @timestamp, srcAddr, pktSrcAddr, dstAddr, pktDstAddr, action",
      "| filter srcAddr != pktSrcAddr or dstAddr != pktDstAddr",
      "| limit 50",
    ])
  } : {}
}

output "reachability_results" {
  description = "Verdict of each Reachability Analyzer path. Empty unless run_reachability_analysis is true."
  value = {
    for key, analysis in aws_ec2_network_insights_analysis.shop :
    key => analysis.path_found ? "REACHABLE" : "NOT REACHABLE"
  }
}

output "verify_observability" {
  description = "Commands for investigating the network."
  value = merge(
    {
      data_nacl_rules = "aws ec2 describe-network-acls --network-acl-ids ${aws_network_acl.data.id} --region ${var.aws_region} --query 'sort_by(NetworkAcls[0].Entries,&RuleNumber)[].{Num:RuleNumber,Egress:Egress,Proto:Protocol,Action:RuleAction,CIDR:CidrBlock,Ports:PortRange}' --output table"

      break_the_shop_then_curl = "curl -s ${local.load_balancer_enabled ? "http://${aws_lb.shop[0].dns_name}/" : "http://${module.web.public_ip}/"}"

      recent_network_changes = "aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=CreateNetworkAclEntry --region ${var.aws_region} --max-results 10 --query 'Events[].{Time:EventTime,User:Username,Event:EventName}' --output table"
    },
    {
      for key, path in aws_ec2_network_insights_path.shop :
      "analyse_${key}_costs_10_cents" => "aws ec2 start-network-insights-analysis --network-insights-path-id ${path.id} --region ${var.aws_region}"
    },
    {
      for key, analysis in aws_ec2_network_insights_analysis.shop :
      "explain_${key}" => "aws ec2 describe-network-insights-analyses --network-insights-analysis-ids ${analysis.id} --region ${var.aws_region} --query 'NetworkInsightsAnalyses[0].{Found:NetworkPathFound,Explanations:Explanations[].{Code:ExplanationCode,Acl:Acl.Id,Rule:AclRule.RuleNumber,SecurityGroup:SecurityGroup.Id}}' --output json"
    },
  )
}
