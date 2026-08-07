locals {
  lab_name    = "03-private-access-and-vpc-endpoints"
  name_prefix = "${var.project_name}-lab03"

  common_tags = merge(
    {
      Project     = var.project_name
      Lab         = local.lab_name
      Environment = "learning"
      ManagedBy   = "terraform"
      Lifecycle   = "ephemeral"
    },
    var.additional_tags,
  )

  az_letters = ["a", "b", "c", "d"]

  # No public subnets at all in this lab. There is nowhere for an internet
  # gateway to be useful, which is precisely the point being made.
  private_subnets = {
    for i in range(var.az_count) : "private-${local.az_letters[i]}" => {
      cidr_block = cidrsubnet(var.vpc_cidr, var.subnet_newbits, i)
      az_index   = i
    }
  }

  first_private_subnet_key = "private-${local.az_letters[0]}"

  create_interface_endpoints = var.enable_interface_endpoints && var.acknowledge_costs

  # Interface endpoints go in ONE subnet. Each subnet an endpoint is placed in
  # gets its own ENI and its own hourly charge, so spreading three endpoints
  # across two zones doubles the bill from ~USD 24 to ~USD 48 a month for no
  # benefit in a lab.
  interface_endpoint_subnet_ids = [module.vpc.private_subnet_ids[local.first_private_subnet_key]]

  interface_endpoint_map = local.create_interface_endpoints ? {
    for svc in var.interface_endpoints : svc => {}
  } : {}

  interface_endpoint_eni_count = length(local.interface_endpoint_map) * length(local.interface_endpoint_subnet_ids)

  # An endpoint policy restricts what can be reached THROUGH the endpoint. It
  # grants nothing: the caller's IAM policy must also allow the action. Both
  # have to say yes.
  #
  # Deliberately narrow: this lab's bucket and nothing else.
  #
  # A restrictive endpoint policy has a consequence worth experiencing rather
  # than being told about. Amazon Linux serves its package repositories from
  # AWS-owned S3 buckets, so with this policy in force `dnf` on the instance
  # stops working -- and it fails with a timeout that looks exactly like a
  # network fault. The README's exercise 4 walks through finding the repository
  # bucket names from the instance and widening the policy correctly, which is
  # the same investigation you would do for a real workload.
  s3_endpoint_policy = var.restrict_s3_endpoint_to_lab_bucket ? jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid       = "AllowLabBucketOnly"
          Effect    = "Allow"
          Principal = "*"
          Action = [
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:ListBucket",
            "s3:GetBucketLocation",
          ]
          Resource = [
            aws_s3_bucket.lab.arn,
            "${aws_s3_bucket.lab.arn}/*",
          ]
        },
      ],
      # Populated by the learner in exercise 4, once they have discovered the
      # real repository bucket names from the instance itself.
      length(var.additional_s3_endpoint_bucket_arns) > 0 ? [
        {
          Sid       = "AllowAdditionalBuckets"
          Effect    = "Allow"
          Principal = "*"
          Action    = ["s3:GetObject", "s3:ListBucket"]
          Resource = flatten([
            for arn in var.additional_s3_endpoint_bucket_arns : [arn, "${arn}/*"]
          ])
        },
      ] : [],
    )
  }) : null

  # Rough standing cost. Gateway endpoints contribute zero.
  estimated_hourly_usd = (
    local.interface_endpoint_eni_count * 0.011
    + (var.enable_test_instance ? 0.0053 : 0)
  )
}
