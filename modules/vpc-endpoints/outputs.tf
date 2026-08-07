output "gateway_endpoint_ids" {
  description = "Map of service short name to gateway endpoint ID."
  value       = { for k, v in aws_vpc_endpoint.gateway : k => v.id }
}

output "gateway_endpoint_prefix_list_ids" {
  description = "Managed prefix list ID for each gateway endpoint. This is what appears as the destination in your route tables, and what you reference in a security group rule to allow traffic to S3 without hardcoding IP ranges."
  value       = { for k, v in aws_vpc_endpoint.gateway : k => v.prefix_list_id }
}

output "interface_endpoint_ids" {
  description = "Map of service short name to interface endpoint ID."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "interface_endpoint_dns_entries" {
  description = "DNS names and hosted zone IDs for each interface endpoint. The Regional name (the one without an AZ prefix) is what private DNS points the public service hostname at."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.dns_entry }
}

output "interface_endpoint_network_interface_ids" {
  description = "ENI IDs backing each interface endpoint. These consume addresses from your subnet CIDR and are what you are billed for per hour."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.network_interface_ids }
}

output "endpoint_security_group_id" {
  description = "ID of the security group created for the interface endpoints, or null when create_security_group is false."
  value       = one(aws_security_group.endpoints[*].id)
}

output "interface_endpoint_eni_count" {
  description = "Total number of endpoint ENIs created. Each costs roughly USD 0.011 per hour in ap-southeast-1, about USD 8 per month, plus data processing."
  value       = sum(concat([0], [for k, v in aws_vpc_endpoint.interface : length(coalesce(v.subnet_ids, []))]))
}

output "estimated_monthly_cost_usd" {
  description = "Rough standing cost of the interface endpoints, excluding data processing. Gateway endpoints contribute nothing because they are free."
  value       = format("~USD %.2f/month for %d interface endpoint ENIs (gateway endpoints are free)", sum(concat([0], [for k, v in aws_vpc_endpoint.interface : length(coalesce(v.subnet_ids, []))])) * 8.03, sum(concat([0], [for k, v in aws_vpc_endpoint.interface : length(coalesce(v.subnet_ids, []))])))
}
