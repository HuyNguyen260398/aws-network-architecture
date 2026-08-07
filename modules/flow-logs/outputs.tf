output "flow_log_id" {
  description = "ID of the flow log."
  value       = aws_flow_log.this.id
}

output "flow_log_arn" {
  description = "ARN of the flow log."
  value       = aws_flow_log.this.arn
}

output "log_group_name" {
  description = "CloudWatch log group receiving records, or null when delivering to S3. Use it with 'aws logs tail' or Logs Insights."
  value       = one(aws_cloudwatch_log_group.this[*].name)
}

output "log_group_arn" {
  description = "ARN of the CloudWatch log group, or null when delivering to S3."
  value       = one(aws_cloudwatch_log_group.this[*].arn)
}

output "iam_role_arn" {
  description = "ARN of the delivery role, or null when delivering to S3 (S3 delivery uses a bucket policy instead of a role)."
  value       = one(aws_iam_role.this[*].arn)
}

output "tail_command" {
  description = "Ready-to-run command that streams new flow log records to your terminal. Records appear after the aggregation interval elapses, so allow up to ten minutes with the default 600-second setting."
  value = local.to_cloudwatch ? join(" ", [
    "aws logs tail",
    aws_cloudwatch_log_group.this[0].name,
    "--follow --region ${data.aws_region.current.region}",
  ]) : "Delivering to S3; query with Amazon Athena rather than 'aws logs tail'."
}

output "rejected_traffic_query" {
  description = "CloudWatch Logs Insights query that lists rejected flows, most recent first. Paste it into the Logs Insights console against the log group above. Rejected flows are how you confirm a security group or network ACL is the thing blocking a connection."
  value = local.to_cloudwatch ? join("\n", [
    "fields @timestamp, srcAddr, dstAddr, srcPort, dstPort, protocol, action",
    "| filter action = \"REJECT\"",
    "| sort @timestamp desc",
    "| limit 50",
  ]) : "Not applicable for S3 delivery."
}
