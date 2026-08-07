# =============================================================================
# AWS Budgets alarm
#
# Not a networking resource, but the cheapest insurance a learning account can
# buy. A forgotten NAT gateway costs about USD 32 a month; a forgotten Network
# Firewall endpoint costs about USD 285. A budget email tells you in hours
# rather than at the end of the billing cycle.
#
# The first two budgets in an AWS account are free.
# =============================================================================

resource "aws_budgets_budget" "this" {
  count = var.create ? 1 : 0

  name         = var.name
  budget_type  = "COST"
  limit_amount = format("%.2f", var.limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  tags = var.tags

  # Alert on money already spent.
  dynamic "notification" {
    for_each = toset(var.alert_thresholds_percent)

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = var.notification_emails
    }
  }

  # Alert on money AWS predicts you are about to spend. This is the one that
  # catches an hourly resource left running overnight, before the month ends.
  dynamic "notification" {
    for_each = var.forecast_alert ? [100] : []

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "FORECASTED"
      subscriber_email_addresses = var.notification_emails
    }
  }

  lifecycle {
    precondition {
      condition     = !var.create || length(var.notification_emails) > 0
      error_message = "notification_emails must contain at least one address, otherwise the budget is created but can never notify anyone."
    }
  }
}
