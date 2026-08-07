provider "aws" {
  region = var.aws_region

  # Applied to every taggable resource in this lab, so individual resources only
  # need to add their own Name. This is what makes cleanup verifiable:
  #   aws resourcegroupstaggingapi get-resources --tag-filters Key=Lab,Values=<lab>
  default_tags {
    tags = local.common_tags
  }
}
