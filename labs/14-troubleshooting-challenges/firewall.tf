variable "enable_network_firewall" {
  description = <<-EOT
    Deploy AWS Network Firewall and route traffic between the public subnets
    and the app subnet in zone A through it.

    ###################################################################
    COST: about USD 0.395 per firewall-endpoint-hour in ap-southeast-1,
    plus about USD 0.065 per GB inspected. That is USD 9.48 A DAY and
    roughly USD 288 A MONTH for a single endpoint.

    THIS IS THE MOST EXPENSIVE RESOURCE IN THIS REPOSITORY.
    ###################################################################

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
  description = "TCP port the firewall's Suricata rule drops. The default is a port nothing in the shop uses, so enabling the firewall changes nothing until you set this to 9090 and watch the payment service disappear."
  type        = number
  default     = 9999

  validation {
    condition     = var.firewall_blocked_port >= 1 && var.firewall_blocked_port <= 65535
    error_message = "firewall_blocked_port must be between 1 and 65535."
  }
}

locals {
  create_firewall = var.enable_network_firewall && var.acknowledge_costs

  firewall_endpoint_id = local.create_firewall ? one([
    for state in tolist(aws_networkfirewall_firewall.this[0].firewall_status[0].sync_states) :
    state.attachment[0].endpoint_id
  ]) : null
}

# -----------------------------------------------------------------------------
# A subnet of its own
#
# The firewall endpoint needs a subnet whose route table does NOT send traffic
# to the firewall, or every packet would loop. So this subnet is built here,
# with its own route table holding only the local route, rather than as one
# more private subnet sharing the zone's route table.
# -----------------------------------------------------------------------------
resource "aws_subnet" "firewall" {
  count = local.create_firewall ? 1 : 0

  vpc_id            = module.vpc.vpc_id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 30)
  availability_zone = module.vpc.availability_zones[0]

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-firewall-a" })
}

resource "aws_route_table" "firewall" {
  count = local.create_firewall ? 1 : 0

  vpc_id = module.vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-rt-firewall" })
}

resource "aws_route_table_association" "firewall" {
  count = local.create_firewall ? 1 : 0

  subnet_id      = aws_subnet.firewall[0].id
  route_table_id = aws_route_table.firewall[0].id
}

# =============================================================================
# AWS Network Firewall -- opt-in, ~USD 0.395/hour
#
# A managed, stateful firewall with Suricata-compatible rules: the cloud
# version of the NETWORK firewall that sits between two zones. It inspects
# EAST-WEST traffic between the public subnets and the app subnet in zone A.
#
# The firewall is not in the path by itself. Traffic reaches it only because
# route tables send it there, in BOTH directions -- a stateful firewall that
# sees half a conversation drops it.
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
        drop tcp any any -> any ${var.firewall_blocked_port} (msg:"Shop firewall blocked port"; sid:1000001; rev:1;)
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
    subnet_id = aws_subnet.firewall[0].id
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

# -----------------------------------------------------------------------------
# Inspection routing
#
# These routes are MORE SPECIFIC than the VPC's local route, so they win:
# longest prefix match applies inside a VPC too.
# -----------------------------------------------------------------------------

# Public subnets -> app-a goes to the firewall instead of straight there.
resource "aws_route" "public_to_app_via_firewall" {
  count = local.create_firewall ? 1 : 0

  route_table_id         = module.vpc.public_route_table_id
  destination_cidr_block = local.app_subnets["app-a"].cidr_block
  vpc_endpoint_id        = local.firewall_endpoint_id
}

# ...and the replies come back the same way. One route per public subnet,
# because the load balancer has a node in each.
resource "aws_route" "app_to_public_via_firewall" {
  for_each = local.create_firewall ? local.public_subnets : {}

  route_table_id         = module.vpc.private_route_table_ids["0"]
  destination_cidr_block = each.value.cidr_block
  vpc_endpoint_id        = local.firewall_endpoint_id
}

check "firewall_is_disabled" {
  assert {
    condition     = !local.create_firewall
    error_message = "AWS Network Firewall is ENABLED at about USD 0.395/hour -- USD 9.48/day, USD 288/month. This is the most expensive resource in this repository. Turn it off as soon as you have finished the exercise."
  }
}

output "firewall_endpoint_id" {
  description = "VPC endpoint ID of the firewall -- the target of the inspection routes. Null when the firewall is disabled."
  value       = local.firewall_endpoint_id
}

output "verify_firewall" {
  description = "Commands for checking the firewall. Empty when it is disabled."
  value = local.create_firewall ? {
    firewall_status = "aws network-firewall describe-firewall --firewall-name ${aws_networkfirewall_firewall.this[0].name} --region ${var.aws_region} --query 'FirewallStatus.Status' --output text"

    inspection_routes = "aws ec2 describe-route-tables --route-table-ids ${module.vpc.public_route_table_id} ${module.vpc.private_route_table_ids["0"]} --region ${var.aws_region} --query 'RouteTables[].Routes[?VpcEndpointId!=`null`].{Dest:DestinationCidrBlock,Firewall:VpcEndpointId}' --output table"

    alert_log = "aws logs tail ${aws_cloudwatch_log_group.firewall_alerts[0].name} --region ${var.aws_region} --since 15m"
  } : {}
}
