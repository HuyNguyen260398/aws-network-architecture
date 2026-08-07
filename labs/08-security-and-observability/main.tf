# =============================================================================
# Lab 08 -- Security and observability
#
# Two filtering mechanisms, one telemetry source, and one analyser:
#
#   Security group   stateful, on an ENI, allow-only
#   Network ACL      stateless, on a subnet, allow AND deny, ordered
#   VPC Flow Logs    metadata about every flow, including ACCEPT or REJECT
#   Reachability     static analysis of the path, naming the blocking component
#   Analyzer
#
# The lab is built around one question that comes up in every network
# investigation: was the packet BLOCKED, or did it never ARRIVE? Flow logs
# answer it. A REJECT record means something filtered it; no record at all means
# routing sent it nowhere.
#
# COSTS
#   Flow logs to CloudWatch Logs   ~USD 0.50/GB ingested -- cents for a lab
#   Reachability Analyzer          USD 0.10 per analysis
#   CloudTrail management events   first copy free, plus S3 storage  (opt-in)
#   AWS Network Firewall           ~USD 0.395/hour + USD 0.065/GB    (opt-in)
# =============================================================================

data "aws_caller_identity" "current" {}

module "vpc" {
  source = "../../modules/vpc"

  name       = local.name_prefix
  cidr_block = var.vpc_cidr

  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  create_internet_gateway = true
  nat_gateway_mode        = "none"

  tags = local.common_tags
}

# =============================================================================
# VPC Flow Logs
#
# A custom format, because the AWS default (version 2) omits the fields that
# matter once traffic has been translated or has crossed a gateway.
#   pkt-srcaddr / pkt-dstaddr  the ORIGINAL addresses, before NAT rewrote them
#   flow-direction             ingress or egress, from the ENI's point of view
#   traffic-path               which gateway the traffic left through
# =============================================================================
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

  log_format = join(" ", [
    "$${version}", "$${vpc-id}", "$${subnet-id}", "$${instance-id}", "$${interface-id}",
    "$${srcaddr}", "$${dstaddr}", "$${srcport}", "$${dstport}", "$${protocol}",
    "$${packets}", "$${bytes}", "$${start}", "$${end}",
    "$${action}", "$${log-status}",
    "$${pkt-srcaddr}", "$${pkt-dstaddr}", "$${flow-direction}", "$${traffic-path}",
  ])

  tags = local.common_tags
}

# =============================================================================
# Security groups -- stateful, allow-only
#
# The server's group ALLOWS the service port from the client's group. Nothing in
# the security group layer blocks this lab's traffic; every rejection you see in
# the flow logs comes from the network ACL below or from the firewall.
# =============================================================================
resource "aws_security_group" "client" {
  name_prefix = "${local.name_prefix}-client-"
  description = "Client host. Outbound only."
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-client" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "client_all" {
  security_group_id = aws_security_group.client.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-client-egress" })
}

resource "aws_security_group" "server" {
  name_prefix = "${local.name_prefix}-server-"
  description = "Server host. Service port from the client security group only."
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-server" })

  lifecycle {
    create_before_destroy = true
  }
}

# Referencing the client's security group rather than a CIDR. Note there is no
# corresponding outbound rule for the reply -- security groups are STATEFUL, so
# the response to an allowed inbound connection is permitted automatically.
resource "aws_vpc_security_group_ingress_rule" "server_from_client" {
  security_group_id            = aws_security_group.server.id
  description                  = "Service port from the client security group"
  ip_protocol                  = "tcp"
  from_port                    = local.service_port
  to_port                      = local.service_port
  referenced_security_group_id = aws_security_group.client.id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-server-ingress" })
}

resource "aws_vpc_security_group_ingress_rule" "server_icmp" {
  security_group_id = aws_security_group.server.id
  description       = "ICMP echo request from within the VPC"
  ip_protocol       = "icmp"
  from_port         = 8
  to_port           = -1
  cidr_ipv4         = var.vpc_cidr

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-server-icmp" })
}

resource "aws_vpc_security_group_egress_rule" "server_all" {
  security_group_id = aws_security_group.server.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-server-egress" })
}

# =============================================================================
# Network ACL -- stateless, ordered, supports DENY
#
# This is what actually blocks the lab's traffic. The security groups above
# permit it; the ACL denies it at the subnet boundary. In the flow logs the
# result is a REJECT record, which is how you tell "filtered" from "never
# arrived".
# =============================================================================
resource "aws_network_acl" "private" {
  vpc_id     = module.vpc.vpc_id
  subnet_ids = [module.vpc.private_subnet_ids["private-a"]]

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-nacl-private" })
}

# Rule 90: the deny, deliberately numbered BELOW the allow at 100 so that it is
# evaluated first. Network ACL rules are processed in ascending order and
# evaluation stops at the first match.
resource "aws_network_acl_rule" "deny_service_port" {
  count = var.enable_nacl_block ? 1 : 0

  network_acl_id = aws_network_acl.private.id
  rule_number    = 90
  egress         = false
  protocol       = "tcp"
  rule_action    = "deny"
  cidr_block     = var.vpc_cidr
  from_port      = var.nacl_block_port
  to_port        = var.nacl_block_port
}

resource "aws_network_acl_rule" "allow_vpc_inbound" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 100
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
}

# Return traffic for connections this subnet initiated. Stateless filtering
# means the reply needs its own rule; a security group would have handled it.
resource "aws_network_acl_rule" "allow_ephemeral_inbound" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "allow_all_outbound" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

# =============================================================================
# Test instances
# =============================================================================
module "client" {
  count  = var.enable_test_instances ? 1 : 0
  source = "../../modules/test-instance"

  name          = "${local.name_prefix}-client"
  vpc_id        = module.vpc.vpc_id
  subnet_id     = module.vpc.public_subnet_ids["public-a"]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  associate_public_ip_address = true
  create_security_group       = false
  security_group_ids          = [aws_security_group.client.id]

  tags = merge(local.common_tags, { Role = "client" })
}

module "server" {
  count  = var.enable_test_instances ? 1 : 0
  source = "../../modules/test-instance"

  name          = "${local.name_prefix}-server"
  vpc_id        = module.vpc.vpc_id
  subnet_id     = module.vpc.private_subnet_ids["private-a"]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  associate_public_ip_address = false
  create_security_group       = false
  security_group_ids          = [aws_security_group.server.id]

  user_data = local.server_user_data

  tags = merge(local.common_tags, { Role = "server" })
}

# =============================================================================
# Reachability Analyzer
#
# Static analysis of the configuration: no packet is sent. It evaluates route
# tables, security groups, network ACLs, gateways and endpoints, and when a path
# is unreachable it names the exact component that blocks it.
#
# Creating a PATH is free. Each ANALYSIS costs USD 0.10.
# =============================================================================
resource "aws_ec2_network_insights_path" "client_to_server" {
  count = var.enable_test_instances ? 1 : 0

  source           = module.client[0].primary_network_interface_id
  destination      = module.server[0].primary_network_interface_id
  protocol         = "tcp"
  destination_port = local.service_port

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-client-to-server" })
}

resource "aws_ec2_network_insights_analysis" "client_to_server" {
  count = var.enable_test_instances && var.run_reachability_analysis ? 1 : 0

  network_insights_path_id = aws_ec2_network_insights_path.client_to_server[0].id
  wait_for_completion      = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-analysis" })
}

# A second path, to a port the SECURITY GROUP does not allow. Running both
# analyses and comparing the answers is the exercise: same source, same
# destination, same everything -- and Reachability Analyzer names a different
# blocking component for each, because one is stopped by the network ACL and
# the other by the security group.
resource "aws_ec2_network_insights_path" "client_to_server_ssh" {
  count = var.enable_test_instances ? 1 : 0

  source           = module.client[0].primary_network_interface_id
  destination      = module.server[0].primary_network_interface_id
  protocol         = "tcp"
  destination_port = 22

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-client-to-server-ssh" })
}

resource "aws_ec2_network_insights_analysis" "client_to_server_ssh" {
  count = var.enable_test_instances && var.run_reachability_analysis ? 1 : 0

  network_insights_path_id = aws_ec2_network_insights_path.client_to_server_ssh[0].id
  wait_for_completion      = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-analysis-ssh" })
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

# =============================================================================
# AWS Network Firewall -- opt-in, ~USD 0.395/hour
#
# A managed, stateful firewall with Suricata-compatible rules. This lab inspects
# EAST-WEST traffic between the public and private subnets rather than egress to
# the internet -- same inspection-routing pattern, without also needing a NAT
# gateway.
# =============================================================================
resource "aws_networkfirewall_rule_group" "block_service_port" {
  count = local.create_firewall ? 1 : 0

  name     = "${local.name_prefix}-block"
  capacity = 100
  type     = "STATEFUL"

  rule_group {
    rules_source {
      # Suricata rule syntax. `drop` silently discards; `reject` would send a
      # TCP RST, which is friendlier to clients and noisier to attackers.
      rules_source_list {
        generated_rules_type = "DENYLIST"
        target_types         = ["TLS_SNI", "HTTP_HOST"]
        targets              = ["example.invalid"]
      }
    }
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-block-rules" })
}

resource "aws_networkfirewall_rule_group" "drop_port" {
  count = local.create_firewall ? 1 : 0

  name     = "${local.name_prefix}-drop-port"
  capacity = 100
  type     = "STATEFUL"

  rule_group {
    rules_source {
      rules_string = <<-RULES
        drop tcp any any -> any ${var.firewall_blocked_port} (msg:"Lab 08 blocked service port"; sid:1000001; rev:1;)
      RULES
    }
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-drop-port-rules" })
}

resource "aws_networkfirewall_firewall_policy" "this" {
  count = local.create_firewall ? 1 : 0

  name = "${local.name_prefix}-policy"

  firewall_policy {
    # Stateless rules run first and are cheap. Anything they do not decide is
    # forwarded to the stateful engine.
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.drop_port[0].arn
    }

    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.block_service_port[0].arn
    }
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-policy" })
}

resource "aws_networkfirewall_firewall" "this" {
  count = local.create_firewall ? 1 : 0

  name                = "${local.name_prefix}-firewall"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.this[0].arn
  vpc_id              = module.vpc.vpc_id

  # Disabled so `terraform destroy` works. Leave it ON in production -- this is
  # the resource whose accidental deletion opens every path it was inspecting.
  delete_protection = false

  subnet_mapping {
    subnet_id = module.vpc.private_subnet_ids["firewall-a"]
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-firewall" })
}

resource "aws_cloudwatch_log_group" "firewall_alerts" {
  count = local.create_firewall ? 1 : 0

  name              = "/aws/network-firewall/${local.name_prefix}/alert"
  retention_in_days = var.flow_log_retention_days

  tags = local.common_tags
}

resource "aws_networkfirewall_logging_configuration" "this" {
  count = local.create_firewall ? 1 : 0

  firewall_arn = aws_networkfirewall_firewall.this[0].arn

  logging_configuration {
    log_destination_config {
      log_destination_type = "CloudWatchLogs"
      log_type             = "ALERT"

      log_destination = {
        logGroup = aws_cloudwatch_log_group.firewall_alerts[0].name
      }
    }
  }
}

# Inspection routing. Traffic from the public subnet toward the private subnet
# is sent to the firewall endpoint instead of straight to its destination.
#
# The firewall subnet's own route table must NOT point back at the firewall, or
# every packet loops. That is why the firewall gets a dedicated subnet.
resource "aws_route" "public_to_private_via_firewall" {
  count = local.create_firewall ? 1 : 0

  route_table_id         = module.vpc.public_route_table_id
  destination_cidr_block = local.private_subnets["private-a"].cidr_block
  vpc_endpoint_id        = local.firewall_endpoint_id
}

check "firewall_is_disabled" {
  assert {
    condition     = !local.create_firewall
    error_message = "AWS Network Firewall is ENABLED at about USD 0.395/hour -- USD 9.48/day, USD 288/month. This is the most expensive resource in this repository. Destroy the lab as soon as you have finished the exercise."
  }
}
