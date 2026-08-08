# =============================================================================
# Lab 10 -- Troubleshooting challenges
#
# THIS LAB DEPLOYS DELIBERATELY BROKEN INFRASTRUCTURE.
#
# Every fault below is real, is the kind that occurs in production, and fails
# the way the real thing fails: silently, with a timeout, and with every
# component reporting itself healthy.
#
# Safety properties, all deliberate:
#   - Nothing is reachable from the internet except through Session Manager.
#   - No inbound port is opened to 0.0.0.0/0.
#   - Every scenario is confined to this lab's own VPCs.
#   - Every resource is tagged Warning = intentionally-misconfigured.
#
# Work each challenge before opening HINTS.md, and open SOLUTIONS.md last.
#
# COST: about USD 0.016/hour with the test instances (USD 0.026 when a
# challenge needs the peer VPC). Nothing here is billed by the hour beyond the
# instances and, for one challenge, a few cents of flow logs.
# =============================================================================

module "base_vpc" {
  source = "../../modules/vpc"

  name       = "${local.name_prefix}-base"
  cidr_block = var.base_vpc_cidr

  public_subnets  = local.base_public_subnets
  private_subnets = local.base_private_subnets

  create_internet_gateway = true
  nat_gateway_mode        = "none"

  tags = merge(local.common_tags, { Role = "base" })
}

module "peer_vpc" {
  count  = local.need_peer_vpc ? 1 : 0
  source = "../../modules/vpc"

  name       = "${local.name_prefix}-peer"
  cidr_block = var.peer_vpc_cidr

  public_subnets          = local.peer_subnets
  create_internet_gateway = true
  nat_gateway_mode        = "none"

  tags = merge(local.common_tags, { Role = "peer" })
}

# =============================================================================
# CHALLENGE: overlapping-cidr
#
# A second VPC using the SAME CIDR as the base VPC. Creating it is perfectly
# legal -- AWS does not care that two of your VPCs share a range. The task is to
# peer them, discover that you cannot, and reason about the alternatives.
# =============================================================================
module "overlap_vpc" {
  count  = local.need_overlap_vpc ? 1 : 0
  source = "../../modules/vpc"

  name       = "${local.name_prefix}-overlap"
  cidr_block = var.base_vpc_cidr

  public_subnets = {
    "public-a" = {
      cidr_block              = cidrsubnet(var.base_vpc_cidr, var.subnet_newbits, 0)
      az_index                = 0
      map_public_ip_on_launch = false
    }
  }

  create_internet_gateway = false
  nat_gateway_mode        = "none"

  tags = merge(local.common_tags, { Role = "overlap", Challenge = "overlapping-cidr" })
}

# =============================================================================
# CHALLENGE: missing-route  /  asymmetric-routing
#
# A peering connection that is 'active' and carries nothing, because the routes
# are incomplete.
# =============================================================================
resource "aws_vpc_peering_connection" "peer" {
  count = local.need_peer_vpc ? 1 : 0

  vpc_id      = module.base_vpc.vpc_id
  peer_vpc_id = module.peer_vpc[0].vpc_id
  auto_accept = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-pcx" })
}

# The base VPC gets its route. Note what is NOT here: the return route in the
# peer VPC. The connection is active, one side knows where to send packets, and
# the other has no idea where to send the replies.
resource "aws_route" "base_to_peer" {
  count = local.need_peer_vpc ? 1 : 0

  route_table_id            = module.base_vpc.public_route_table_id
  destination_cidr_block    = var.peer_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peer[0].id
}

# Present ONLY for the asymmetric-routing challenge, where the peer side does
# have a return route -- so the failure is subtler than in missing-route: some
# subnets work and some do not.
resource "aws_route" "peer_to_base" {
  count = local.c.asymmetric_routing ? 1 : 0

  route_table_id            = module.peer_vpc[0].public_route_table_id
  destination_cidr_block    = var.base_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peer[0].id
}

# The asymmetric-routing challenge puts app-a and app-b in different route
# tables (modules/vpc creates one per AZ) and adds the peering route to only
# one of them. Two apparently identical subnets, one reachable.
resource "aws_route" "app_a_to_peer" {
  count = local.c.asymmetric_routing ? 1 : 0

  route_table_id            = module.base_vpc.private_route_table_ids["0"]
  destination_cidr_block    = var.peer_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peer[0].id
}

# =============================================================================
# CHALLENGE: security-group
#
# The server allows the service port -- from the WRONG source. The rule looks
# entirely reasonable in the console.
# =============================================================================
resource "aws_security_group" "client" {
  name_prefix = "${local.name_prefix}-client-"
  description = "Client host"
  vpc_id      = module.base_vpc.vpc_id

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
  description = "Server host"
  vpc_id      = module.base_vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-server" })

  lifecycle {
    create_before_destroy = true
  }
}

# The broken rule. It permits the service port from the SERVER's own security
# group rather than from the client's -- a copy-paste error that reads as
# correct at a glance and is invisible in a rule listing unless you check the
# group ID against the one you expected.
resource "aws_vpc_security_group_ingress_rule" "server_wrong_source" {
  count = local.c.security_group ? 1 : 0

  security_group_id            = aws_security_group.server.id
  description                  = "Service port from the application tier"
  ip_protocol                  = "tcp"
  from_port                    = local.service_port
  to_port                      = local.service_port
  referenced_security_group_id = aws_security_group.server.id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-server-ingress", Challenge = "security-group" })
}

# The correct rule, used whenever the security-group challenge is NOT enabled,
# so that the other challenges are not confounded by this one.
resource "aws_vpc_security_group_ingress_rule" "server_correct_source" {
  count = local.c.security_group ? 0 : 1

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
  description       = "ICMP echo request from within the lab"
  ip_protocol       = "icmp"
  from_port         = 8
  to_port           = -1
  cidr_ipv4         = "10.100.0.0/14"

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
# CHALLENGE: nacl-ephemeral  /  flow-log-rejects
#
# A network ACL that allows everything you would think to check, and drops the
# return traffic for outbound connections.
# =============================================================================
resource "aws_network_acl" "private" {
  count = local.c.nacl_ephemeral || local.c.flow_log_rejects ? 1 : 0

  vpc_id     = module.base_vpc.vpc_id
  subnet_ids = [module.base_vpc.private_subnet_ids["app-a"]]

  tags = merge(local.common_tags, {
    Name      = "${local.name_prefix}-nacl-private"
    Challenge = local.c.nacl_ephemeral ? "nacl-ephemeral" : "flow-log-rejects"
  })
}

# Inbound from the VPC is allowed. This is the rule people check, and it is
# fine. What is missing is any allow for the EPHEMERAL port range, which is
# where replies to outbound connections arrive.
resource "aws_network_acl_rule" "private_in_vpc" {
  count = local.c.nacl_ephemeral || local.c.flow_log_rejects ? 1 : 0

  network_acl_id = aws_network_acl.private[0].id
  rule_number    = 100
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = var.base_vpc_cidr
}

# Outbound is wide open, which is what makes this confusing: every rule you
# look at says the traffic is permitted.
resource "aws_network_acl_rule" "private_out_all" {
  count = local.c.nacl_ephemeral || local.c.flow_log_rejects ? 1 : 0

  network_acl_id = aws_network_acl.private[0].id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

# For flow-log-rejects specifically, an explicit deny on the service port, so
# there is a clean REJECT record to find rather than an absence of records.
resource "aws_network_acl_rule" "private_deny_service" {
  count = local.c.flow_log_rejects ? 1 : 0

  network_acl_id = aws_network_acl.private[0].id
  rule_number    = 90
  egress         = false
  protocol       = "tcp"
  rule_action    = "deny"
  cidr_block     = var.base_vpc_cidr
  from_port      = local.service_port
  to_port        = local.service_port
}

module "flow_logs" {
  count  = local.need_flow_logs ? 1 : 0
  source = "../../modules/flow-logs"

  name          = local.name_prefix
  resource_type = "VPC"
  resource_id   = module.base_vpc.vpc_id

  traffic_type = "ALL"
  # 60 seconds rather than 600: a troubleshooting exercise where the evidence
  # takes ten minutes to arrive is a bad exercise.
  max_aggregation_interval = 60
  log_retention_days       = var.flow_log_retention_days

  tags = local.common_tags
}

# =============================================================================
# CHALLENGE: broken-dns
#
# A private hosted zone with a perfectly good record in it, associated with a
# VPC that has DNS support switched off -- so nothing in that VPC can resolve
# anything at all, let alone the zone.
# =============================================================================
module "dns_vpc" {
  count  = local.c.broken_dns ? 1 : 0
  source = "../../modules/vpc"

  name       = "${local.name_prefix}-dns"
  cidr_block = "10.102.0.0/16"

  public_subnets = {
    "public-a" = {
      cidr_block              = "10.102.0.0/24"
      az_index                = 0
      map_public_ip_on_launch = false
    }
  }

  # The fault. With DNS support off, the Amazon-provided resolver at the VPC
  # base address plus two does not answer, so private hosted zones, VPC
  # endpoint private DNS and instance private DNS names all stop working.
  # The VPC itself looks entirely normal in the console.
  enable_dns_support   = false
  enable_dns_hostnames = false

  create_internet_gateway = false
  nat_gateway_mode        = "none"

  tags = merge(local.common_tags, { Role = "dns", Challenge = "broken-dns" })
}

resource "aws_route53_zone" "challenge" {
  count = local.c.broken_dns ? 1 : 0

  name    = "lab10.internal"
  comment = "Troubleshooting challenge: the zone and its record are both correct"

  vpc {
    vpc_id     = module.dns_vpc[0].vpc_id
    vpc_region = var.aws_region
  }

  tags = merge(local.common_tags, { Name = "lab10.internal", Challenge = "broken-dns" })
}

resource "aws_route53_record" "challenge" {
  count = local.c.broken_dns ? 1 : 0

  zone_id = aws_route53_zone.challenge[0].zone_id
  name    = "target.lab10.internal"
  type    = "A"
  ttl     = 60
  records = ["10.102.0.99"]
}

# =============================================================================
# CHALLENGE: endpoint-policy  /  missing-association
# =============================================================================
resource "random_id" "bucket_suffix" {
  count = local.need_s3_endpoint ? 1 : 0

  byte_length = 4
}

resource "aws_s3_bucket" "challenge" {
  # Versioning and Block Public Access ARE configured, immediately below.
  # Checkov cannot evaluate `local.need_s3_endpoint` (it is derived from a
  # contains() call over a set variable), so it fails to link this bucket to its
  # count-indexed companion resources and reports them missing. The suppressions
  # are for that analysis gap, not for a real one -- delete them and read the
  # next thirty lines if you want to check.
  #checkov:skip=CKV_AWS_21:Versioning is configured by aws_s3_bucket_versioning.challenge below
  #checkov:skip=CKV2_AWS_6:Block Public Access is configured by aws_s3_bucket_public_access_block.challenge below
  count = local.need_s3_endpoint ? 1 : 0

  bucket        = "${local.name_prefix}-${random_id.bucket_suffix[0].hex}"
  force_destroy = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-bucket" })
}

resource "aws_s3_bucket_public_access_block" "challenge" {
  count = local.need_s3_endpoint ? 1 : 0

  bucket = aws_s3_bucket.challenge[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "challenge" {
  count = local.need_s3_endpoint ? 1 : 0

  bucket = aws_s3_bucket.challenge[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "challenge" {
  count = local.need_s3_endpoint ? 1 : 0

  bucket = aws_s3_bucket.challenge[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "challenge" {
  count = local.need_s3_endpoint ? 1 : 0

  bucket       = aws_s3_bucket.challenge[0].id
  key          = "target.txt"
  content      = "If you can read this, the endpoint and its policy are both correct.\n"
  content_type = "text/plain"

  tags = local.common_tags
}

module "s3_endpoint" {
  count  = local.need_s3_endpoint ? 1 : 0
  source = "../../modules/vpc-endpoints"

  name   = local.name_prefix
  vpc_id = module.base_vpc.vpc_id

  gateway_endpoints = {
    s3 = {
      # CHALLENGE endpoint-policy: an endpoint policy that allows a DIFFERENT
      # bucket. It is syntactically valid, it looks purposeful, and it denies
      # the only bucket that matters -- by omission rather than by an explicit
      # Deny, which is what makes it hard to spot.
      policy = local.c.endpoint_policy ? jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid       = "AllowApprovedBucketsOnly"
            Effect    = "Allow"
            Principal = "*"
            Action    = ["s3:GetObject", "s3:ListBucket"]
            Resource = [
              "arn:aws:s3:::${local.name_prefix}-approved",
              "arn:aws:s3:::${local.name_prefix}-approved/*",
            ]
          },
        ]
      }) : null
    }
  }

  # CHALLENGE missing-association: no route tables. The endpoint is created,
  # reports 'available', and has no effect on any traffic whatsoever, because
  # nothing routes to it.
  #
  # modules/vpc-endpoints has a precondition against exactly this mistake, so
  # the challenge points the endpoint at the PUBLIC route table instead -- which
  # is a real and even more common variant: the endpoint is associated with a
  # route table, just not the one the traffic uses.
  gateway_endpoint_route_table_ids = (
    local.c.missing_association
    ? [module.base_vpc.public_route_table_id]
    : module.base_vpc.all_route_table_ids
  )

  tags = merge(local.common_tags, { Challenge = local.c.endpoint_policy ? "endpoint-policy" : "missing-association" })
}

# =============================================================================
# Test instances
# =============================================================================
module "client" {
  count  = var.enable_test_instances ? 1 : 0
  source = "../../modules/test-instance"

  name          = "${local.name_prefix}-client"
  vpc_id        = module.base_vpc.vpc_id
  subnet_id     = module.base_vpc.public_subnet_ids["public-a"]
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
  vpc_id        = module.base_vpc.vpc_id
  subnet_id     = module.base_vpc.private_subnet_ids["app-a"]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  associate_public_ip_address = false
  create_security_group       = false
  security_group_ids          = [aws_security_group.server.id]

  user_data = local.server_user_data

  # Read access to the challenge bucket, so the endpoint challenges fail on the
  # ENDPOINT rather than on IAM. Distinguishing the two is part of the exercise,
  # and it only works if IAM is genuinely not the problem.
  additional_iam_policy_arns = local.need_s3_endpoint ? {
    s3_readonly = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  } : {}

  tags = merge(local.common_tags, { Role = "server" })
}

module "peer_instance" {
  count  = local.need_peer_vpc && var.enable_test_instances ? 1 : 0
  source = "../../modules/test-instance"

  name          = "${local.name_prefix}-peer"
  vpc_id        = module.peer_vpc[0].vpc_id
  subnet_id     = module.peer_vpc[0].public_subnet_ids["public-a"]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  associate_public_ip_address = true

  ingress_rules = {
    icmp_from_lab = {
      description = "ICMP echo request from anywhere in the lab address space"
      ip_protocol = "icmp"
      from_port   = 8
      to_port     = -1
      cidr_ipv4   = "10.100.0.0/14"
    }
  }

  tags = merge(local.common_tags, { Role = "peer" })
}

check "at_least_one_challenge" {
  assert {
    condition     = length(var.challenges) > 0
    error_message = "No challenges are enabled, so this lab has deployed a working, unremarkable network. Set the `challenges` variable -- see variables.tf for the list."
  }
}

check "one_challenge_at_a_time" {
  assert {
    condition     = length(var.challenges) <= 2
    error_message = "More than two challenges are enabled at once. Interacting faults are realistic but they are a poor way to learn: enable one, diagnose it, destroy, repeat."
  }
}
