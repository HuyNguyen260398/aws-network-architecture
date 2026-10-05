locals {
  # Bucket names are globally unique across every AWS account, so a fixed name
  # such as "awsnet-tfstate" would collide with the first other learner to run
  # this. The random suffix is stored in state, so it stays stable across
  # subsequent applies.
  state_bucket_name = coalesce(var.state_bucket_name, "${var.project_name}-tfstate-${random_id.bucket_suffix.hex}")

  common_tags = merge(
    {
      Project   = var.project_name
      Component = "terraform-backend"
      ManagedBy = "terraform"
      Repo      = "aws-network-handons"
      Purpose   = "aws-networking-labs"
      # Marks this bucket as infrastructure that must outlive the labs, so a
      # cleanup script that sweeps by tag does not take the state bucket with it.
      Lifecycle = "persistent"
    },
    var.additional_tags,
  )

  kms_key_arn = var.create_kms_key ? aws_kms_key.state[0].arn : null

  # S3 rejects a bucket policy document with zero statements, and the TLS deny
  # is the only statement that is always present, so the list is never empty.
  bucket_policy_statements = concat(
    [
      {
        Sid    = "DenyInsecureTransport"
        Effect = "Deny"
        # A wildcard principal in a *Deny* is the correct shape: it denies
        # everyone, including this account, unless the request used TLS.
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.state.arn,
          "${aws_s3_bucket.state.arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
    ],
    var.deny_unencrypted_uploads ? [
      {
        Sid       = "DenyUnencryptedObjectUploads"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = ["${aws_s3_bucket.state.arn}/*"]
        Condition = {
          # StringNotEquals also matches a *missing* header, so this denies both
          # "wrong algorithm" and "no algorithm specified".
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = var.create_kms_key ? "aws:kms" : "AES256"
          }
        }
      },
    ] : [],
  )
}
