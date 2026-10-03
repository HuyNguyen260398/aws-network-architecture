provider "aws" {
  region = var.aws_region

  # Applied to every taggable resource, so individual resources only need to
  # add their own Name. This is what makes cleanup verifiable:
  #   aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=shop
  default_tags {
    tags = local.common_tags
  }
}

# A second Region, for lab 13. Every resource and module that should live
# there says so explicitly with `provider = aws.dr`; anything that does not
# is created in aws_region above.
provider "aws" {
  alias  = "dr"
  region = var.dr_region

  default_tags {
    tags = local.common_tags
  }
}
