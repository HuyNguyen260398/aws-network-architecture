# =============================================================================
# Private access to AWS services.
#
# The shop stores its product images in S3 and its hosts are managed through
# Systems Manager. Both are AWS services with public endpoints, so in lab 03
# the private tiers reached them through the NAT gateway -- paying a per-GB
# processing charge to talk to a service in the same Region.
#
# VPC endpoints give the VPC a private path to the service instead:
#
#   gateway endpoint    a ROUTE in the route table.   S3 and DynamoDB. Free.
#   interface endpoint  an ENI with a private address. Most services. Billed.
# =============================================================================

variable "enable_s3_gateway_endpoint" {
  description = "Create the S3 gateway endpoint and add its route to every route table. Free, and strictly better than sending S3 traffic through a NAT gateway."
  type        = bool
  default     = true
}

variable "restrict_s3_endpoint_to_shop_bucket" {
  description = "Attach an endpoint policy that allows only the shop's own bucket. An endpoint policy caps what the endpoint will carry, whatever IAM allows: a host with full S3 permissions still cannot reach another bucket through it."
  type        = bool
  default     = true
}

variable "enable_interface_endpoints" {
  description = <<-EOT
    Create interface endpoints for Systems Manager, so the private hosts can be
    managed with no NAT gateway and no internet path at all.

    COST: roughly USD 0.011/hour per endpoint per Availability Zone. The three
    Session Manager endpoints in one zone are about USD 0.033/hour, or
    USD 24/month, plus USD 0.01 per GB.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_interface_endpoints || var.acknowledge_costs
    error_message = "enable_interface_endpoints requires acknowledge_costs = true. Three interface endpoints cost about USD 24/month."
  }
}

variable "interface_endpoints" {
  description = "Which interface endpoint services to create. ALL THREE defaults are required for Session Manager to work; omitting ec2messages is a classic mistake."
  type        = list(string)
  default     = ["ssm", "ssmmessages", "ec2messages"]
}

locals {
  create_interface_endpoints = var.enable_interface_endpoints && var.acknowledge_costs

  interface_endpoint_map = local.create_interface_endpoints ? {
    for svc in var.interface_endpoints : svc => {}
  } : {}

  # One zone only. Each extra zone is another ENI per service and another
  # hourly charge; a second zone buys availability, which a lab does not need.
  interface_endpoint_subnet_ids = [module.vpc.private_subnet_ids["app-a"]]

  s3_endpoint_policy = var.restrict_s3_endpoint_to_shop_bucket ? jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowShopBucketOnly"
        Effect    = "Allow"
        Principal = "*"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = [
          aws_s3_bucket.assets.arn,
          "${aws_s3_bucket.assets.arn}/*",
        ]
      },
    ]
  }) : null
}

# -----------------------------------------------------------------------------
# The bucket the shop reads its product images from
# -----------------------------------------------------------------------------
resource "random_id" "assets_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "assets" {
  bucket = "${local.name_prefix}-assets-${random_id.assets_suffix.hex}"

  # A learning bucket: let `terraform destroy` empty it.
  force_destroy = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-assets" })
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket = aws_s3_bucket.assets.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "assets" {
  bucket = aws_s3_bucket.assets.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_policy" "assets" {
  bucket = aws_s3_bucket.assets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.assets.arn, "${aws_s3_bucket.assets.arn}/*"]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.assets]
}

resource "aws_s3_object" "hello" {
  bucket       = aws_s3_bucket.assets.id
  key          = "hello.txt"
  content      = "Fetched through the S3 gateway endpoint: a route, not a NAT gateway, and no charge.\n"
  content_type = "text/plain"

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# The endpoints
# -----------------------------------------------------------------------------
module "endpoints" {
  source = "../../modules/vpc-endpoints"

  name   = local.name_prefix
  vpc_id = module.vpc.vpc_id

  gateway_endpoints = var.enable_s3_gateway_endpoint ? {
    s3 = {
      policy = local.s3_endpoint_policy
    }
  } : {}

  # A gateway endpoint works by adding a route whose destination is the S3
  # prefix list. It only exists for the route tables named here.
  gateway_endpoint_route_table_ids = var.enable_s3_gateway_endpoint ? module.vpc.all_route_table_ids : []

  interface_endpoints           = local.interface_endpoint_map
  interface_endpoint_subnet_ids = local.interface_endpoint_subnet_ids

  # Who may connect to the endpoint ENIs on 443.
  allowed_cidr_blocks = [var.vpc_cidr]

  tags = local.common_tags
}

# The app host reads and writes the bucket. Permission comes from IAM; the
# endpoint only decides which path the request takes.
resource "aws_iam_role_policy" "app_assets" {
  name_prefix = "shop-assets-"
  role        = regex("[^/]+$", module.app.iam_role_arn)

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = ["${aws_s3_bucket.assets.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.assets.arn]
      },
    ]
  })
}

check "private_hosts_reachable_via_session_manager" {
  assert {
    condition     = local.create_interface_endpoints || local.nat_gateway_mode != "none"
    error_message = "The private hosts have neither a NAT gateway nor Systems Manager interface endpoints, so 'aws ssm start-session' to the app or database host fails with TargetNotConnected. The S3 gateway endpoint still works and is free; test it once you have a shell. Set acknowledge_costs = true and enable_interface_endpoints = true (~USD 0.033/hour) or enable_nat_gateway = true (~USD 0.059/hour)."
  }
}

output "assets_bucket" {
  description = "Name of the shop's assets bucket."
  value       = aws_s3_bucket.assets.id
}

output "s3_gateway_endpoint_id" {
  description = "ID of the S3 gateway endpoint, or null when disabled."
  value       = try(module.endpoints.gateway_endpoint_ids["s3"], null)
}

output "interface_endpoint_ids" {
  description = "Map of service name to interface endpoint ID. Empty unless enable_interface_endpoints is set."
  value       = module.endpoints.interface_endpoint_ids
}

output "verify_endpoints" {
  description = "Commands for checking private AWS access. Run the last three from a shell on the app server."
  value = {
    endpoints = "aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=${module.vpc.vpc_id} --region ${var.aws_region} --query 'VpcEndpoints[].{Service:ServiceName,Type:VpcEndpointType,State:State,PrivateDns:PrivateDnsEnabled}' --output table"

    s3_route_in_private_route_tables = "aws ec2 describe-route-tables --filters Name=vpc-id,Values=${module.vpc.vpc_id} --region ${var.aws_region} --query 'RouteTables[].Routes[?DestinationPrefixListId!=`null`].{PrefixList:DestinationPrefixListId,Target:GatewayId}' --output table"

    from_app_read_object     = "aws s3 cp s3://${aws_s3_bucket.assets.id}/hello.txt - --region ${var.aws_region}"
    from_app_ssm_resolves_to = "dig +short ssm.${var.aws_region}.amazonaws.com"
  }
}
