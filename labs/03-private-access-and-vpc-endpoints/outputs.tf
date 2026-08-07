output "cost_warning" {
  description = "Standing cost of this lab as currently configured."
  value = join("\n", compact([
    format("Estimated standing cost: ~USD %.4f/hour  (~USD %.2f/day, ~USD %.2f/month)", local.estimated_hourly_usd, local.estimated_hourly_usd * 24, local.estimated_hourly_usd * 730),
    var.enable_s3_gateway_endpoint ? "S3 gateway endpoint: enabled and FREE. No hourly charge, no data processing charge." : "S3 gateway endpoint: disabled.",
    local.create_interface_endpoints ? format("Interface endpoints: %d ENIs at ~USD 0.011/hour EACH (~USD %.2f/month) plus ~USD 0.01/GB processed. THIS IS THE CHARGEABLE PART.", local.interface_endpoint_eni_count, local.interface_endpoint_eni_count * 8.03) : "Interface endpoints: disabled (free). Session Manager will not reach the instance.",
    var.enable_test_instance ? "Test instance: 1 x t4g.nano at ~USD 0.0053/hour." : "Test instance: disabled.",
    "For comparison, the NAT gateway these endpoints replace would cost ~USD 43/month.",
    "Run 'terraform destroy' when finished.",
  ]))
}

output "aws_region" {
  description = "Region this lab deployed into."
  value       = var.aws_region
}

output "vpc_id" {
  description = "ID of the lab VPC. It has no internet gateway."
  value       = module.vpc.vpc_id
}

output "vpc_has_internet_gateway" {
  description = "Always false in this lab. Confirms that everything below works with no path to the internet whatsoever."
  value       = module.vpc.internet_gateway_id != null
}

output "private_subnets" {
  description = "Private subnets. Their route tables contain the local route plus, when the S3 gateway endpoint is enabled, a prefix-list route to S3."
  value       = module.vpc.private_subnets
}

output "route_table_ids" {
  description = "Route tables the S3 gateway endpoint is associated with. A gateway endpoint that is not associated with a route table has no effect at all."
  value       = module.vpc.all_route_table_ids
}

output "s3_bucket_name" {
  description = "Lab bucket, used to prove that S3 is reachable through the gateway endpoint."
  value       = aws_s3_bucket.lab.id
}

output "s3_gateway_endpoint_id" {
  description = "ID of the S3 gateway endpoint, or absent when disabled."
  value       = try(module.endpoints.gateway_endpoint_ids["s3"], null)
}

output "s3_prefix_list_id" {
  description = "Managed prefix list for S3 in this Region. This is the destination that appears in the route tables, and you can reference it in a security group rule to allow traffic to S3 without hardcoding IP ranges that AWS changes."
  value       = try(module.endpoints.gateway_endpoint_prefix_list_ids["s3"], null)
}

output "interface_endpoint_ids" {
  description = "Interface endpoints keyed by service. Empty when they are disabled."
  value       = module.endpoints.interface_endpoint_ids
}

output "interface_endpoint_dns_entries" {
  description = "DNS names for each interface endpoint. With private DNS enabled, the service's public hostname also resolves to these private addresses inside the VPC."
  value       = module.endpoints.interface_endpoint_dns_entries
}

output "instance_id" {
  description = "Instance ID of the private test host."
  value       = one(module.instance[*].instance_id)
}

output "session_manager_command" {
  description = "Opens a shell on the private instance. Only works when interface endpoints are enabled -- there is no other path to Systems Manager from this VPC."
  value       = var.enable_test_instance ? module.instance[0].ssm_start_session_command : null
}

output "in_session_tests" {
  description = "Commands to run once you have a shell on the instance. These are the actual proof that the endpoints work."
  value = var.enable_test_instance ? {
    "1_read_through_gateway_endpoint"  = "aws s3 cp s3://${aws_s3_bucket.lab.id}/hello.txt - --region ${var.aws_region}"
    "2_write_through_gateway_endpoint" = "echo hi | aws s3 cp - s3://${aws_s3_bucket.lab.id}/from-instance.txt --region ${var.aws_region}"
    "3_confirm_no_internet"            = "curl -s --max-time 5 https://checkip.amazonaws.com || echo 'TIMED OUT -- correct, there is no internet gateway'"
    "4_s3_resolves_to_public_ip"       = "dig +short s3.${var.aws_region}.amazonaws.com    # a PUBLIC address: gateway endpoints work by ROUTING, not DNS"
    "5_ssm_resolves_privately"         = "dig +short ssm.${var.aws_region}.amazonaws.com   # a PRIVATE address from your CIDR: interface endpoints work by DNS"
    "6_blocked_bucket_is_denied"       = "aws s3 ls s3://aws-ml-blog --region ${var.aws_region} || echo 'DENIED -- the endpoint policy did its job'"
  } : {}
}

output "verify_commands" {
  description = "Read-only AWS CLI commands for inspecting what was built."
  value = {
    s3_route_in_route_table = "aws ec2 describe-route-tables --route-table-ids ${module.vpc.all_route_table_ids[0]} --region ${var.aws_region} --query 'RouteTables[0].Routes[].{Dest:DestinationCidrBlock,PrefixList:DestinationPrefixListId,Target:GatewayId}' --output table"

    list_endpoints = "aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=${module.vpc.vpc_id} --region ${var.aws_region} --query 'VpcEndpoints[].{Service:ServiceName,Type:VpcEndpointType,State:State,PrivateDNS:PrivateDnsEnabled}' --output table"

    endpoint_enis = "aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=${module.vpc.vpc_id} Name=vpc-endpoint-type,Values=Interface --region ${var.aws_region} --query 'VpcEndpoints[].{Service:ServiceName,ENIs:NetworkInterfaceIds}' --output json"

    endpoint_policy = "aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=${module.vpc.vpc_id} Name=vpc-endpoint-type,Values=Gateway --region ${var.aws_region} --query 'VpcEndpoints[0].PolicyDocument' --output text | jq ."

    confirm_no_igw = "aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values=${module.vpc.vpc_id} --region ${var.aws_region} --query 'InternetGateways' --output json   # expect []"
  }
}
