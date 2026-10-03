# Partial S3 backend configuration.
#
# The bucket and Region come from backend.hcl at init time, so nothing
# account-specific is ever committed:
#
#   cp backend.hcl.example backend.hcl
#   $EDITOR backend.hcl
#   terraform init -backend-config=backend.hcl
#
# Run bootstrap/ first if the state bucket does not exist yet.

terraform {
  backend "s3" {
    # THE SAME KEY IN EVERY LAB, on purpose. Each lab folder is the whole shop
    # project at one stage of its life, so they all describe the same
    # infrastructure and must share one state. Applying lab 05 after lab 04
    # upgrades what lab 04 built; it does not build a second copy.
    key = "shop/terraform.tfstate"

    # Server-side encryption for the state object.
    encrypt = true

    # S3 native state locking: Terraform writes a <key>.tflock object for the
    # duration of an operation. DynamoDB-based locking is deprecated and must
    # not be added here.
    use_lockfile = true
  }
}
