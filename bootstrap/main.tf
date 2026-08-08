# =============================================================================
# Terraform backend bootstrap
#
# This is the ONE root module in this repository that uses local state, and it
# is a deliberate exception: Terraform cannot store state in an S3 bucket that
# does not exist yet. This module creates that bucket. Everything else in the
# repository then uses it as a remote backend.
#
# The generated terraform.tfstate stays on your machine and is gitignored. If you
# would rather have this module's own state in S3 too, see the "Migrating the
# bootstrap state" section of bootstrap/README.md -- it is optional and safe to
# skip for solo learning.
# =============================================================================

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# Four random bytes is 4.3 billion possibilities -- enough to make a global S3
# name collision improbable without producing an unreadable bucket name.
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# -----------------------------------------------------------------------------
# Optional customer-managed KMS key
# -----------------------------------------------------------------------------
resource "aws_kms_key" "state" {
  count = var.create_kms_key ? 1 : 0

  description             = "Encrypts Terraform state for ${var.project_name} networking labs"
  deletion_window_in_days = var.kms_key_deletion_window_days
  enable_key_rotation     = true

  # The key policy delegates authorisation to IAM for principals in this account
  # (the standard AWS pattern), and separately grants the S3 service the
  # operations it performs on your behalf when writing an SSE-KMS object.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableIAMUserPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowS3ServiceUse"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })
}

resource "aws_kms_alias" "state" {
  count = var.create_kms_key ? 1 : 0

  name          = "alias/${var.project_name}-tfstate"
  target_key_id = aws_kms_key.state[0].key_id
}

# -----------------------------------------------------------------------------
# State bucket
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  # `force_destroy` is intentionally NOT exposed as a variable. Combined with
  # versioning, it would let a single `terraform destroy` erase every version of
  # every lab's state with no recovery path. Emptying this bucket should be a
  # conscious, manual act -- see "Deleting the backend" in the README.
  force_destroy = false

  lifecycle {
    # The only prevent_destroy in this repository. Lab resources are disposable
    # and must never carry this, because it would break `terraform destroy` and
    # leave learners paying for infrastructure they cannot remove.
    prevent_destroy = true
  }
}

# Versioning is the recovery mechanism for state corruption: if a lab's state
# object is truncated or deleted, the previous version is still retrievable.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.create_kms_key ? "aws:kms" : "AES256"
      kms_master_key_id = local.kms_key_arn
    }
    # Reuses one data key for many objects, which cuts KMS request charges.
    # Harmless when SSE-S3 is in use.
    bucket_key_enabled = var.create_kms_key
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Disables ACLs entirely. Object ownership is unconditional, which removes a
# whole class of cross-account access mistakes.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  # Interrupted uploads leave parts that are billed but invisible in the console.
  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Old state versions accumulate forever otherwise. Each is small, but a busy
  # learner generates hundreds.
  dynamic "rule" {
    for_each = var.noncurrent_version_expiration_days > 0 ? [1] : []

    content {
      id     = "expire-noncurrent-state-versions"
      status = "Enabled"

      filter {}

      # Repeated from the rule above. S3 applies each rule independently, so a
      # rule without this clause does not inherit it, and an interrupted upload
      # matching only this rule would otherwise be billed indefinitely.
      abort_incomplete_multipart_upload {
        days_after_initiation = 7
      }

      noncurrent_version_expiration {
        noncurrent_days = var.noncurrent_version_expiration_days
        # Always keep the last few versions regardless of age, so there is a
        # rollback target even for a bucket that has been idle for months.
        newer_noncurrent_versions = 5
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.bucket_policy_statements
  })

  # Applying a policy before Block Public Access exists briefly widens the
  # window in which a mistaken policy could take effect.
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# -----------------------------------------------------------------------------
# Optional account budget
#
# Not networking, but the single most useful safety net for a learning account:
# it tells you about a NAT gateway you forgot to destroy before the invoice does.
# -----------------------------------------------------------------------------
module "budget" {
  source = "../modules/budget"

  create                   = var.enable_budget
  name                     = "${var.project_name}-monthly"
  limit_usd                = var.budget_limit_usd
  notification_emails      = var.budget_notification_emails
  alert_thresholds_percent = var.budget_alert_thresholds_percent
  tags                     = local.common_tags
}
