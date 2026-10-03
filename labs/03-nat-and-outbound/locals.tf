locals {
  name_prefix = var.project_name

  # No per-lab tag. Every lab manages the same resources, and a tag that
  # changed from lab to lab would show up as an in-place update on every
  # resource each time you moved on, burying the change the lab is about.
  common_tags = merge(
    {
      Project     = var.project_name
      Environment = "learning"
      ManagedBy   = "terraform"
      Lifecycle   = "ephemeral"
    },
    var.additional_tags,
  )
}
