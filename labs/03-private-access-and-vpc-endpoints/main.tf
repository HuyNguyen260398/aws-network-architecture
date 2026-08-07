# =============================================================================
# Lab 03 -- Private AWS service access with VPC endpoints
#
# This VPC has NO INTERNET GATEWAY. Not a disabled one -- there is no internet
# gateway resource at all, and therefore no possibility of a route to one. The
# private subnets have no default route.
#
# And yet an instance inside it can read and write S3, and (with the interface
# endpoints enabled) can be reached with Session Manager. That is the whole
# lesson: "reaching AWS services" and "having internet access" are different
# things, and conflating them is what leads to a NAT gateway in every VPC.
#
# COSTS
#   S3 gateway endpoint        FREE
#   Interface endpoints        ~USD 0.011/ENI-hour  (opt-in, off by default)
#   t4g.nano                   ~USD 0.0053/hour
#   S3 storage for a few files effectively zero
# =============================================================================

module "vpc" {
  source = "../../modules/vpc"

  name       = local.name_prefix
  cidr_block = var.vpc_cidr

  # No public subnets, and explicitly no internet gateway. A VPC does not need
  # one to reach AWS services.
  public_subnets          = {}
  private_subnets         = local.private_subnets
  create_internet_gateway = false
  nat_gateway_mode        = "none"

  tags = local.common_tags
}

# =============================================================================
# A bucket to prove the gateway endpoint works
# =============================================================================
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "lab" {
  bucket = "${local.name_prefix}-${random_id.bucket_suffix.hex}"

  # Lab data is disposable, and a bucket Terraform cannot empty is a bucket
  # `terraform destroy` fails on. This is safe here precisely because nothing
  # of value is ever stored in it -- do not copy this into production.
  force_destroy = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-bucket" })
}

resource "aws_s3_bucket_public_access_block" "lab" {
  bucket = aws_s3_bucket.lab.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lab" {
  bucket = aws_s3_bucket.lab.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "lab" {
  bucket = aws_s3_bucket.lab.id

  versioning_configuration {
    status = "Enabled"
  }
}

# A bucket policy that refuses non-TLS requests, matching the state bucket in
# bootstrap/. Traffic through a gateway endpoint still uses HTTPS to the S3
# service; the endpoint changes the path, not the protocol.
resource "aws_s3_bucket_policy" "lab" {
  bucket = aws_s3_bucket.lab.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.lab.arn, "${aws_s3_bucket.lab.arn}/*"]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.lab]
}

# A file to fetch from the instance, so the test is a real S3 read.
resource "aws_s3_object" "hello" {
  bucket       = aws_s3_bucket.lab.id
  key          = "hello.txt"
  content      = "Fetched through the S3 gateway endpoint. No internet gateway, no NAT gateway, no charge.\n"
  content_type = "text/plain"

  tags = local.common_tags
}

# =============================================================================
# Endpoints
# =============================================================================
module "endpoints" {
  source = "../../modules/vpc-endpoints"

  name   = local.name_prefix
  vpc_id = module.vpc.vpc_id

  # FREE. A gateway endpoint is a route, not an address. It has no ENI, no
  # security group, and no hourly charge -- and it is completely invisible from
  # outside this VPC, which is why it cannot be used from on-premises.
  gateway_endpoints = var.enable_s3_gateway_endpoint ? {
    s3 = {
      policy = local.s3_endpoint_policy
    }
  } : {}

  # A gateway endpoint does nothing until it is associated with route tables.
  # This is the most common reason one appears not to work.
  gateway_endpoint_route_table_ids = var.enable_s3_gateway_endpoint ? module.vpc.all_route_table_ids : []

  # CHARGEABLE. Each of these is an ENI in your subnet with a private address
  # from your CIDR, billed by the hour whether or not traffic flows.
  interface_endpoints           = local.interface_endpoint_map
  interface_endpoint_subnet_ids = local.interface_endpoint_subnet_ids

  # Interface endpoints speak HTTPS and nothing else.
  allowed_cidr_blocks = [var.vpc_cidr]

  tags = local.common_tags
}

# =============================================================================
# Test instance
# =============================================================================
module "instance" {
  count  = var.enable_test_instance ? 1 : 0
  source = "../../modules/test-instance"

  name          = "${local.name_prefix}-private"
  vpc_id        = module.vpc.vpc_id
  subnet_id     = module.vpc.private_subnet_ids[local.first_private_subnet_key]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  # There is no internet gateway in this VPC, so a public IP would be
  # meaningless even if AWS let us request one.
  associate_public_ip_address = false

  # Read/write access to the lab bucket, so the S3 test is not an IAM failure
  # masquerading as a network failure. Note this grants nothing about *routing*
  # -- the endpoint is what provides the path.
  additional_iam_policy_arns = {
    s3_readonly = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  }

  tags = merge(local.common_tags, { Tier = "private" })
}

# The instance needs write access to exactly one bucket. AmazonS3ReadOnlyAccess
# above covers reads across the account; this adds writes for the lab bucket
# only, rather than reaching for AmazonS3FullAccess.
resource "aws_iam_role_policy" "instance_bucket_write" {
  count = var.enable_test_instance ? 1 : 0

  name_prefix = "lab-bucket-write-"
  role        = regex("[^/]+$", module.instance[0].iam_role_arn)

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = ["${aws_s3_bucket.lab.arn}/*"]
      },
    ]
  })
}

# Warns rather than fails: the lab is useful without interface endpoints (the
# free S3 half still works), but Session Manager will not reach the instance.
check "instance_reachable_via_session_manager" {
  assert {
    condition     = !var.enable_test_instance || local.create_interface_endpoints
    error_message = "Interface endpoints are disabled, so the instance has no path to Systems Manager and 'aws ssm start-session' will fail with TargetNotConnected. The S3 gateway endpoint half of this lab still works and is free. Set acknowledge_costs = true and enable_interface_endpoints = true (~USD 0.033/hour) to get a shell."
  }
}
