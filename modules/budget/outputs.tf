output "budget_arn" {
  description = "ARN of the created budget, or null when create is false."
  value       = one(aws_budgets_budget.this[*].arn)
}

output "budget_name" {
  description = "Name of the created budget, or null when create is false."
  value       = one(aws_budgets_budget.this[*].name)
}
