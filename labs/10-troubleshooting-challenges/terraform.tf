terraform {
  # 1.11 is the floor: it is where S3 native state locking (use_lockfile) is the
  # supported mechanism and DynamoDB locking is deprecated.
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # The challenge bucket needs a globally unique name.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}
