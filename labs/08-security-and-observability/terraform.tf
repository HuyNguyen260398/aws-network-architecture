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
    # The optional CloudTrail bucket needs a globally unique name.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}
