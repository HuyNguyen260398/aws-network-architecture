variable "aws_region" {
  description = "AWS Region in which to create the Terraform state bucket. Every lab must be initialised against this same Region, because an S3 backend is Region-specific."
  type        = string
  default     = "ap-southeast-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must look like an AWS Region identifier, for example ap-southeast-1 or eu-west-2."
  }
}

variable "project_name" {
  description = "Short prefix used in resource names and in the Project tag. Keep it lowercase and DNS-safe, because it becomes part of the S3 bucket name."
  type        = string
  default     = "awsnet"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,20}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-22 characters of lowercase letters, digits and hyphens, and must start and end with a letter or digit."
  }
}

variable "state_bucket_name" {
  description = "Explicit name for the state bucket. Leave null to generate '<project_name>-tfstate-<random suffix>', which is the recommended path: S3 bucket names are globally unique across all AWS accounts, and a random suffix avoids both collisions and disclosing your account identity in a guessable name."
  type        = string
  default     = null

  validation {
    condition     = var.state_bucket_name == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name == null ? "placeholder" : var.state_bucket_name))
    error_message = "state_bucket_name must be a valid S3 bucket name: 3-63 characters, lowercase letters, digits, hyphens and dots, starting and ending alphanumerically."
  }
}

variable "create_kms_key" {
  description = "Create a customer-managed KMS key and use it for state bucket encryption instead of S3-managed keys (SSE-S3). SSE-S3 is free; a customer-managed key costs roughly USD 1 per month plus request charges. SSE-S3 already encrypts your state at rest, so leave this false unless you specifically want to learn key policies or need auditable key usage."
  type        = bool
  default     = false
}

variable "kms_key_deletion_window_days" {
  description = "Waiting period before a scheduled KMS key deletion completes. Only used when create_kms_key is true. AWS enforces a minimum of 7 days."
  type        = number
  default     = 7

  validation {
    condition     = var.kms_key_deletion_window_days >= 7 && var.kms_key_deletion_window_days <= 30
    error_message = "kms_key_deletion_window_days must be between 7 and 30."
  }
}

variable "deny_unencrypted_uploads" {
  description = <<-EOT
    Add a bucket policy statement that rejects any PutObject which does not carry
    an explicit server-side-encryption header.

    Default is false, deliberately. The bucket already has default encryption
    enabled, so every object is encrypted at rest whether or not the caller sends
    the header -- this statement only enforces the *header*, and a mismatch
    produces an opaque 403 that is genuinely hard to debug from Terraform. Turn it
    on once you are comfortable with the failure mode.
  EOT
  type        = bool
  default     = false
}

variable "noncurrent_version_expiration_days" {
  description = "Delete non-current versions of state objects after this many days. Versioning is what lets you recover from a corrupted or accidentally deleted state file, so do not set this aggressively low. Set to 0 to keep every version forever."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_expiration_days == 0 || var.noncurrent_version_expiration_days >= 30
    error_message = "noncurrent_version_expiration_days must be 0 (keep forever) or at least 30, so that state history stays recoverable."
  }
}

variable "enable_budget" {
  description = "Create an AWS Budget that emails you when spend crosses a threshold. Budgets themselves are free (the first two action-free budgets per account are), and this is the cheapest insurance against a forgotten NAT gateway. Requires budget_notification_emails to be non-empty."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_budget || length(var.budget_notification_emails) > 0
    error_message = "Set budget_notification_emails to at least one address when enable_budget is true, otherwise the budget cannot notify anyone."
  }
}

variable "budget_limit_usd" {
  description = "Monthly budget limit in USD used when enable_budget is true. Alerts fire at the percentages listed in budget_alert_thresholds_percent."
  type        = number
  default     = 20

  validation {
    condition     = var.budget_limit_usd > 0
    error_message = "budget_limit_usd must be greater than zero."
  }
}

variable "budget_notification_emails" {
  description = "Email addresses to notify when a budget threshold is crossed. AWS sends a subscription confirmation to each address."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.budget_notification_emails : can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[a-zA-Z]{2,}$", e))])
    error_message = "Every entry in budget_notification_emails must be a valid email address."
  }
}

variable "budget_alert_thresholds_percent" {
  description = "Percentages of budget_limit_usd at which to send an alert. Values above 100 alert on forecasted overspend."
  type        = list(number)
  default     = [50, 80, 100]

  validation {
    condition     = length(var.budget_alert_thresholds_percent) > 0 && alltrue([for t in var.budget_alert_thresholds_percent : t > 0 && t <= 200])
    error_message = "budget_alert_thresholds_percent must be a non-empty list of numbers between 1 and 200."
  }
}

variable "additional_tags" {
  description = "Extra tags merged into the default tags applied to every resource. Useful for a cost-allocation tag or an owner tag your organisation requires."
  type        = map(string)
  default     = {}
}
