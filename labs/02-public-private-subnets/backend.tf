# Partial S3 backend configuration.
#
# Only the state key lives here, because it is the one value that is a property
# of this lab rather than of your AWS account. The bucket and Region come from
# backend.hcl at init time, so nothing account-specific is ever committed:
#
#   cp backend.hcl.example backend.hcl
#   $EDITOR backend.hcl
#   terraform init -backend-config=backend.hcl
#
# Run bootstrap/ first if the state bucket does not exist yet.

terraform {
  backend "s3" {
    # UNIQUE PER LAB. Two labs sharing a key overwrite each other's state.
    key = "labs/02-public-private-subnets/terraform.tfstate"

    # Server-side encryption for the state object.
    encrypt = true

    # S3 native state locking: Terraform writes a <key>.tflock object for the
    # duration of an operation. DynamoDB-based locking is deprecated and must
    # not be added here.
    use_lockfile = true
  }
}
