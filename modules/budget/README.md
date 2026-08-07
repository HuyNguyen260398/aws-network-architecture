# `modules/budget`

An AWS Budget that emails you when account spend crosses a threshold.

Disabled by default. Set `create = true` and supply at least one email address.

## Why this is in a networking repository

Networking is where AWS learning accounts leak money, because the expensive
resources are billed per hour whether or not any traffic flows through them:

| Resource | Cost if left running for a month |
| --- | --- |
| NAT gateway | ~USD 32 |
| Transit Gateway attachment (each) | ~USD 36 |
| Site-to-Site VPN connection | ~USD 36 |
| Route 53 Resolver endpoint (2 ENIs) | ~USD 180 |
| Network Firewall endpoint | ~USD 285 |

None of these appear on a bill until the month closes. A forecast alert fires
within hours.

## Usage

```hcl
module "budget" {
  source = "../../modules/budget"

  create              = true
  name                = "awsnet-monthly"
  limit_usd           = 20
  notification_emails = ["you@example.com"]
}
```

## Behaviour

- One `ACTUAL` notification per entry in `alert_thresholds_percent`
  (default 50%, 80%, 100%).
- One `FORECASTED` notification at 100% when `forecast_alert` is true (default).
  This is the useful one — it fires on projected spend, before the money is gone.
- AWS sends each address a subscription confirmation. Alerts do not arrive until
  it is accepted.

## Cost

The first two budgets per AWS account are free. Beyond that, AWS charges roughly
USD 0.02 per budget per day.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `create` | `bool` | `false` | Whether to create the budget. |
| `name` | `string` | — | Budget name, unique within the account. |
| `limit_usd` | `number` | `20` | Monthly limit in USD. |
| `notification_emails` | `list(string)` | `[]` | Alert recipients. Required when `create` is true. |
| `alert_thresholds_percent` | `list(number)` | `[50, 80, 100]` | Percentages of the limit that trigger ACTUAL alerts. |
| `forecast_alert` | `bool` | `true` | Add a FORECASTED alert at 100%. |
| `tags` | `map(string)` | `{}` | Tags applied to the budget. |

## Outputs

| Name | Description |
| --- | --- |
| `budget_arn` | ARN of the budget, or `null` when not created. |
| `budget_name` | Name of the budget, or `null` when not created. |

## Further reading

- [AWS Budgets](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html) — AWS
- [`aws_budgets_budget`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/budgets_budget) — Terraform Registry
