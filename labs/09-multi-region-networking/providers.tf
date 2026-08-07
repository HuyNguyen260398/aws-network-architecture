# Two provider configurations, because a Region is a hard boundary in AWS: every
# API call targets exactly one Region, and a resource in ap-southeast-1 cannot
# be created by a provider configured for us-east-1.
#
# The AWS provider v6 also allows a per-resource `region` argument, but explicit
# aliases keep it obvious in every resource block which Region it lands in --
# which matters more in a teaching repository than the brevity does.

provider "aws" {
  region = var.primary_region

  default_tags {
    tags = local.common_tags
  }
}

provider "aws" {
  alias  = "secondary"
  region = var.secondary_region

  default_tags {
    tags = local.common_tags
  }
}
