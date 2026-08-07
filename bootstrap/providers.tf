provider "aws" {
  region = var.aws_region

  # Applied to every taggable resource this module creates, so nothing has to
  # remember to tag itself. Learners can add their own via `additional_tags`.
  default_tags {
    tags = local.common_tags
  }
}
