terraform {
  # 1.11 is the floor: it is where S3 native state locking (use_lockfile) is the
  # supported mechanism and DynamoDB locking is deprecated. Cross-variable
  # validation blocks, used by the cost gates in this lab, need 1.9+.
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # S3 bucket names are globally unique across every AWS account, so the lab
    # bucket needs a random suffix rather than a fixed name.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}
