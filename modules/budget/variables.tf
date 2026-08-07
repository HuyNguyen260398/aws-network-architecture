variable "create" {
  description = "Whether to create the budget. Kept as an explicit flag rather than requiring the caller to wrap the module in a count, so callers read the same whether or not budgets are enabled."
  type        = bool
  default     = false
}

variable "name" {
  description = "Name of the budget. Must be unique within the AWS account."
  type        = string

  validation {
    condition     = length(var.name) > 0 && length(var.name) <= 100
    error_message = "name must be between 1 and 100 characters."
  }
}

variable "limit_usd" {
  description = "Monthly cost limit in USD. Alerts fire at percentages of this figure."
  type        = number
  default     = 20

  validation {
    condition     = var.limit_usd > 0
    error_message = "limit_usd must be greater than zero."
  }
}

variable "notification_emails" {
  description = "Email addresses that receive budget alerts. AWS sends each address a subscription confirmation which must be accepted before alerts arrive."
  type        = list(string)
  default     = []
}

variable "alert_thresholds_percent" {
  description = "Percentages of limit_usd at which to alert on ACTUAL spend. A FORECASTED alert at 100 percent is added separately when forecast_alert is true."
  type        = list(number)
  default     = [50, 80, 100]

  validation {
    condition     = alltrue([for t in var.alert_thresholds_percent : t > 0 && t <= 200])
    error_message = "Each threshold must be between 1 and 200 percent."
  }
}

variable "forecast_alert" {
  description = "Also alert when AWS forecasts that the month will exceed the limit. This is the alert that gives you time to act, because it fires before the money is spent."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to the budget."
  type        = map(string)
  default     = {}
}
