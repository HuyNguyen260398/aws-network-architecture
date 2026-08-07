locals {
  # Amazon Linux 2023 image names look like
  #   al2023-ami-2023.12.20260803.3-kernel-6.1-arm64
  # so a wildcard on the version portion always resolves to the current release.
  ami_name_filter = coalesce(
    var.ami_name_filter,
    "al2023-ami-2023.*-kernel-6.1-${var.architecture}",
  )

  ami_id = coalesce(var.ami_id, try(data.aws_ami.this[0].id, null))

  # Instance type families that require arm64 images. Launching an x86_64 AMI on
  # a Graviton instance fails with an unhelpful "InvalidParameterValue".
  is_graviton_type = can(regex("^(t4g|m6g|m6gd|m7g|m7gd|m8g|c6g|c6gd|c6gn|c7g|c7gd|c7gn|c8g|r6g|r6gd|r7g|r7gd|r8g|a1|x2gd|im4gn|is4gen|g5g)\\.", var.instance_type))

  create_role = var.enable_ssm || length(var.additional_iam_policy_arns) > 0

  security_group_ids = compact(concat(
    var.create_security_group ? [aws_security_group.this[0].id] : [],
    var.security_group_ids,
  ))

  tags = merge(var.tags, { Name = var.name })
}
