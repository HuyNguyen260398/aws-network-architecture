output "state_bucket_name" {
  description = "Name of the S3 bucket holding Terraform state. Put this in every lab's backend.hcl as `bucket`."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket, for writing IAM policies that grant lab access to it."
  value       = aws_s3_bucket.state.arn
}

output "state_bucket_region" {
  description = "Region the state bucket lives in. Put this in every lab's backend.hcl as `region`. An S3 backend is Region-specific: initialising a lab with a different Region here will fail."
  value       = var.aws_region
}

output "kms_key_arn" {
  description = "ARN of the customer-managed KMS key encrypting state, or null when SSE-S3 is in use. When set, add it to backend.hcl as `kms_key_id`."
  value       = local.kms_key_arn
}

output "backend_hcl" {
  description = "Ready-to-paste contents for each lab's backend.hcl. The `key` is supplied by each lab's own backend.tf and is deliberately absent here."
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.id}"
    region       = "${var.aws_region}"
    encrypt      = true
    use_lockfile = true${var.create_kms_key ? "\n    kms_key_id   = \"${local.kms_key_arn}\"" : ""}
  EOT
}

output "init_command_example" {
  description = "Example command for initialising a lab against this backend."
  value       = "terraform -chdir=labs/01-single-server init -backend-config=backend.hcl"
}

output "budget_arn" {
  description = "ARN of the optional account budget, or null when enable_budget is false."
  value       = module.budget.budget_arn
}

output "cost_notice" {
  description = "What this module costs to keep running."
  value = join(" ", compact([
    "State bucket storage is a few kilobytes per lab: effectively free (well under USD 0.01/month).",
    var.create_kms_key ? "A customer-managed KMS key costs about USD 1.00/month plus request charges." : "SSE-S3 encryption is free.",
    var.enable_budget ? "AWS Budgets: the first two budgets per account are free." : "",
    "This module creates NO networking resources and NO hourly-billed resources.",
  ]))
}
