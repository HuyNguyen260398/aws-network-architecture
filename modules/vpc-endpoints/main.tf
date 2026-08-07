# =============================================================================
# VPC endpoints
#
# Two mechanisms with the same purpose -- reach an AWS service without traversing
# the internet -- and completely different implementations:
#
#   Gateway endpoint (S3, DynamoDB only)
#     A ROUTE. AWS adds a managed prefix list destination to the route tables
#     you nominate. No ENI, no IP address, no security group, no cost. It is
#     invisible from outside the VPC and cannot be reached over VPN, Direct
#     Connect, or a peering connection.
#
#   Interface endpoint (nearly every other service)
#     An ENI IN YOUR SUBNET with a private IP from your CIDR, fronted by AWS
#     PrivateLink. It has a security group, it is billed hourly per ENI, and
#     because it is an ordinary address in your VPC it IS reachable from
#     on-premises over VPN or Direct Connect.
#
# That last difference is usually what decides which one a design needs.
# =============================================================================

data "aws_region" "current" {}

# Looking the service name up rather than composing
# "com.amazonaws.<region>.<service>" by hand means a typo fails at plan time
# with a clear error, instead of at apply time with an opaque one. It also
# handles the services whose endpoint names do not follow the pattern.
data "aws_vpc_endpoint_service" "gateway" {
  for_each = var.gateway_endpoints

  service      = each.key
  service_type = "Gateway"
}

data "aws_vpc_endpoint_service" "interface" {
  for_each = var.interface_endpoints

  service      = each.key
  service_type = "Interface"
}

locals {
  tags = merge(var.tags, { Name = var.name })

  create_endpoint_sg = var.create_security_group && length(var.interface_endpoints) > 0

  endpoint_security_group_ids = local.create_endpoint_sg ? [aws_security_group.endpoints[0].id] : []
}

# -----------------------------------------------------------------------------
# Gateway endpoints -- free
# -----------------------------------------------------------------------------
resource "aws_vpc_endpoint" "gateway" {
  for_each = var.gateway_endpoints

  vpc_id            = var.vpc_id
  service_name      = data.aws_vpc_endpoint_service.gateway[each.key].service_name
  vpc_endpoint_type = "Gateway"

  # Terraform manages these associations, so a route table added here later is
  # picked up on the next apply. Omitting a table is the most common reason a
  # gateway endpoint "does not work".
  route_table_ids = var.gateway_endpoint_route_table_ids

  # A null policy means full access, which is the AWS default. A policy here
  # restricts what can be reached THROUGH this endpoint; it does not grant
  # anything the caller's IAM policy does not already allow. Both must permit
  # the call.
  policy = each.value.policy

  tags = merge(local.tags, { Name = "${var.name}-${each.key}-gw" })

  lifecycle {
    precondition {
      condition     = length(var.gateway_endpoint_route_table_ids) > 0
      error_message = "gateway_endpoint_route_table_ids is empty. A gateway endpoint that is not associated with any route table has no effect at all -- traffic keeps using whatever the default route says."
    }
  }
}

# -----------------------------------------------------------------------------
# Interface endpoints -- billed per ENI-hour
# -----------------------------------------------------------------------------
resource "aws_security_group" "endpoints" {
  count = local.create_endpoint_sg ? 1 : 0

  name_prefix = "${var.name}-vpce-"
  description = "HTTPS from the VPC to the ${var.name} interface VPC endpoints"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${var.name}-vpce-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# Interface endpoints terminate TLS on port 443 and speak nothing else, so this
# is the whole rule set. There is no egress rule because the endpoint never
# initiates a connection.
resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each = local.create_endpoint_sg ? toset(var.allowed_cidr_blocks) : toset([])

  security_group_id = aws_security_group.endpoints[0].id
  description       = "HTTPS from ${each.value}"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value

  tags = merge(local.tags, { Name = "${var.name}-vpce-https" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.interface_endpoints

  vpc_id            = var.vpc_id
  service_name      = data.aws_vpc_endpoint_service.interface[each.key].service_name
  vpc_endpoint_type = "Interface"

  subnet_ids         = coalesce(each.value.subnet_ids, var.interface_endpoint_subnet_ids)
  security_group_ids = coalesce(each.value.security_group_ids, local.endpoint_security_group_ids)
  ip_address_type    = each.value.ip_address_type

  # With private DNS on, the endpoint takes over the service's public hostname
  # inside this VPC -- ssm.ap-southeast-1.amazonaws.com resolves to the ENI's
  # private address. Unmodified SDKs and the AWS CLI then use the endpoint with
  # no configuration change, which is the whole point.
  private_dns_enabled = each.value.private_dns_enabled

  policy = each.value.policy

  tags = merge(local.tags, { Name = "${var.name}-${each.key}-if" })

  lifecycle {
    precondition {
      condition     = length(coalesce(each.value.subnet_ids, var.interface_endpoint_subnet_ids)) > 0
      error_message = "Interface endpoint '${each.key}' has no subnets. Set interface_endpoint_subnet_ids, or subnet_ids on this endpoint."
    }

    precondition {
      condition     = length(coalesce(each.value.security_group_ids, local.endpoint_security_group_ids)) > 0
      error_message = "Interface endpoint '${each.key}' has no security group. Either leave create_security_group true (and set allowed_cidr_blocks) or pass security_group_ids."
    }
  }
}
