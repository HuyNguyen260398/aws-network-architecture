terraform {
  # 1.11 is the floor for this repository because it is the release where S3
  # native state locking (`use_lockfile`) is the supported mechanism and the
  # DynamoDB locking table is deprecated. Cross-variable `validation` blocks
  # (used for the cost gates in the labs) need 1.9+, so 1.11 covers both.
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}
