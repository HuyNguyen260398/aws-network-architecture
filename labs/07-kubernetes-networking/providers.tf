provider "aws" {
  region = var.aws_region

  # Applied to every taggable resource, so individual resources only need to
  # add their own Name. This is what makes cleanup verifiable:
  #   aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=shop
  default_tags {
    tags = local.common_tags
  }
}
