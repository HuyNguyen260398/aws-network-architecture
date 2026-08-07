output "cost_warning" {
  description = "Standing cost of this lab as currently configured."
  value = join("\n", compact([
    format("Estimated standing cost: ~USD %.4f/hour  (~USD %.2f/day, ~USD %.2f/month)", local.estimated_hourly_usd, local.estimated_hourly_usd * 24, local.estimated_hourly_usd * 730),
    format("Private hosted zones: %d at USD 0.50/month each, regardless of query volume.", var.split_horizon_domain == null ? 1 : 2),
    local.create_privatelink ? "PrivateLink: Network Load Balancer ~USD 0.0225/hour + LCUs, plus one endpoint ENI per subnet at ~USD 0.011/hour." : "PrivateLink: disabled (free).",
    local.create_resolver_inbound ? "Route 53 Resolver INBOUND endpoint: USD 0.25/hour (USD 180/month). AWS mandates two ENIs. THIS IS EXPENSIVE." : "",
    local.create_resolver_outbound ? "Route 53 Resolver OUTBOUND endpoint: USD 0.25/hour (USD 180/month). AWS mandates two ENIs. THIS IS EXPENSIVE." : "",
    (local.create_resolver_inbound || local.create_resolver_outbound) ? "Turn the Resolver endpoints off as soon as you have finished with them." : "",
    "Run 'terraform destroy' when finished.",
  ]))
}

output "aws_region" {
  description = "Region this lab deployed into."
  value       = var.aws_region
}

output "vpc_ids" {
  description = "Provider and consumer VPC IDs."
  value       = { for k, v in module.vpc : k => v.vpc_id }
}

output "vpc_cidrs" {
  description = "Provider and consumer VPC CIDRs. PrivateLink does not exchange routes, so these are allowed to be identical -- try it."
  value       = local.vpcs
}

output "private_hosted_zone_id" {
  description = "Zone ID of the private hosted zone. It resolves only from the VPCs it is associated with."
  value       = aws_route53_zone.private.zone_id
}

output "private_zone_name" {
  description = "Name of the private hosted zone."
  value       = aws_route53_zone.private.name
}

output "split_horizon_zone_id" {
  description = "Zone ID of the split-horizon demonstration zone, or null when disabled. Inside these VPCs it overrides the public answer for the same domain."
  value       = one(aws_route53_zone.split_horizon[*].zone_id)
}

output "privatelink_service_name" {
  description = "Service name a consumer needs to create an interface endpoint to this service. In a real deployment you hand this string to the consuming team; it is all they need, and it reveals nothing about your network."
  value       = one(aws_vpc_endpoint_service.provider[*].service_name)
}

output "privatelink_endpoint_dns" {
  description = "Generated DNS name of the consumer's interface endpoint. Ugly on purpose -- this is why the private hosted zone alias exists."
  value       = local.create_privatelink ? aws_vpc_endpoint.consumer[0].dns_entry[0].dns_name : null
}

output "privatelink_friendly_name" {
  description = "The friendly alias in the private hosted zone that points at the endpoint. This is what a consumer application should actually use."
  value       = local.create_privatelink ? "service.${var.private_zone_name}" : null
}

output "resolver_inbound_ips" {
  description = "IP addresses of the inbound Resolver endpoint. On-premises DNS servers forward queries here to resolve names in this VPC's private hosted zones. You can prove it works from inside the VPC with 'dig @<ip> <name>'."
  value       = local.create_resolver_inbound ? [for ip in aws_route53_resolver_endpoint.inbound[0].ip_address : ip.ip] : []
}

output "resolver_outbound_endpoint_id" {
  description = "ID of the outbound Resolver endpoint, or null when disabled."
  value       = one(aws_route53_resolver_endpoint.outbound[*].id)
}

output "resolver_forward_rule" {
  description = "Which domain the outbound Resolver forwards, and to where. In this lab the targets are RFC 5737 documentation addresses that will not answer -- the rule is real, the servers are not."
  value = local.create_resolver_outbound ? {
    domain  = var.forward_domain
    targets = var.forward_target_ips
    note    = "Queries for this domain now go to the addresses above instead of being answered by AWS. With no server there they time out, which is exactly what a misconfigured on-premises forwarder looks like."
  } : null
}

output "consumer_instance_id" {
  description = "Instance ID of the consumer host."
  value       = one(module.consumer_instance[*].instance_id)
}

output "session_manager_command" {
  description = "Opens a shell on the consumer instance, from which all the DNS tests are run."
  value       = one(module.consumer_instance[*].ssm_start_session_command)
}

output "dns_tests" {
  description = "Commands to run from the consumer instance. These are the proof."
  value = var.enable_test_instances ? merge(
    {
      "1_private_zone" = "dig +short consumer.${var.private_zone_name}   # resolves ONLY inside the associated VPCs"
      "2_vpc_resolver" = "cat /etc/resolv.conf   # the nameserver is the VPC base address plus two"
      "3_from_laptop"  = "dig +short consumer.${var.private_zone_name}   # run this on your LAPTOP: NXDOMAIN, because private zones are VPC-scoped"
    },
    var.split_horizon_domain != null ? {
      "4_split_horizon_inside"  = "dig +short ${var.split_horizon_domain}   # a PRIVATE address from the consumer VPC"
      "5_split_horizon_outside" = "dig +short ${var.split_horizon_domain}   # run on your LAPTOP: the real public answer"
    } : {},
    local.create_privatelink ? {
      "6_privatelink_ugly_name"   = "curl -s http://${aws_vpc_endpoint.consumer[0].dns_entry[0].dns_name}:8080/"
      "7_privatelink_friendly"    = "curl -s http://service.${var.private_zone_name}:8080/"
      "8_endpoint_resolves_local" = "dig +short service.${var.private_zone_name}   # a private address in the CONSUMER VPC, not the provider's"
    } : {},
    local.create_resolver_inbound ? {
      "9_query_inbound_endpoint" = "dig @${aws_route53_resolver_endpoint.inbound[0].ip_address[*].ip[0]} +short consumer.${var.private_zone_name}   # what an on-premises server would do"
    } : {},
    local.create_resolver_outbound ? {
      "10_forwarded_domain" = "dig +short test.${var.forward_domain}   # times out: the rule forwards to servers that do not exist"
    } : {},
  ) : {}
}

output "verify_commands" {
  description = "Read-only AWS CLI commands for inspecting DNS and PrivateLink."
  value = {
    list_hosted_zones = "aws route53 list-hosted-zones-by-vpc --vpc-id ${module.vpc["consumer"].vpc_id} --vpc-region ${var.aws_region} --query 'HostedZoneSummaries[].{Name:Name,Id:HostedZoneId}' --output table"

    zone_records = "aws route53 list-resource-record-sets --hosted-zone-id ${aws_route53_zone.private.zone_id} --query 'ResourceRecordSets[].{Name:Name,Type:Type,Value:ResourceRecords[0].Value}' --output table"

    endpoint_service = local.create_privatelink ? "aws ec2 describe-vpc-endpoint-service-configurations --region ${var.aws_region} --filters Name=service-id,Values=${aws_vpc_endpoint_service.provider[0].id} --query 'ServiceConfigurations[].{Name:ServiceName,State:ServiceState,AcceptanceRequired:AcceptanceRequired}' --output table" : "PrivateLink is disabled."

    endpoint_connections = local.create_privatelink ? "aws ec2 describe-vpc-endpoint-connections --region ${var.aws_region} --filters Name=service-id,Values=${aws_vpc_endpoint_service.provider[0].id} --query 'VpcEndpointConnections[].{Endpoint:VpcEndpointId,Owner:VpcEndpointOwner,State:VpcEndpointState}' --output table" : "PrivateLink is disabled."

    resolver_endpoints = "aws route53resolver list-resolver-endpoints --region ${var.aws_region} --query 'ResolverEndpoints[].{Name:Name,Direction:Direction,Status:Status,IpCount:IpAddressCount}' --output table"

    resolver_rules = "aws route53resolver list-resolver-rules --region ${var.aws_region} --query 'ResolverRules[].{Name:Name,Domain:DomainName,Type:RuleType,Status:Status}' --output table"
  }
}
