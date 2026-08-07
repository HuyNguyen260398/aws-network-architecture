output "cost_warning" {
  description = "Standing cost of this lab as currently configured."
  value = join("\n", compact([
    format("Estimated standing cost: ~USD %.4f/hour  (~USD %.2f/day, ~USD %.2f/month)", local.estimated_hourly_usd, local.estimated_hourly_usd * 24, local.estimated_hourly_usd * 730),
    var.enable_vpc_peering ? "Inter-Region VPC peering: FREE to create. Data crossing it costs about USD 0.02/GB in EACH direction -- roughly double the same-Region rate." : "Inter-Region VPC peering: disabled.",
    local.create_tgw_peering ? "Transit Gateway peering: 4 attachments at ~USD 0.05/hour each = ~USD 0.20/hour (~USD 146/month), plus data processing in both Regions." : "Transit Gateway peering: disabled (free).",
    var.enable_route53_health_checks ? "Route 53 health checks: USD 0.50/month each, plus USD 0.10/month per CloudWatch alarm." : "",
    var.enable_test_instances ? "Test instances: 2 x t4g.nano + 2 public IPv4 addresses, ~USD 0.021/hour." : "",
    "Remember to destroy in BOTH Regions -- 'terraform destroy' handles it, but a partial failure can leave resources in the secondary Region that you will not see in your usual console view.",
  ]))
}

output "primary_region" {
  description = "Primary Region."
  value       = var.primary_region
}

output "secondary_region" {
  description = "Secondary Region. Resources here do not appear in the console unless you switch Regions, which is the most common reason multi-Region labs leak cost."
  value       = var.secondary_region
}

output "vpc_ids" {
  description = "VPC IDs in each Region."
  value = {
    primary   = module.primary_vpc.vpc_id
    secondary = module.secondary_vpc.vpc_id
  }
}

output "vpc_cidrs" {
  description = "VPC CIDRs. Inter-Region peering has exactly the same non-overlapping requirement as same-Region peering."
  value = {
    primary   = var.primary_vpc_cidr
    secondary = var.secondary_vpc_cidr
  }
}

output "peering_connection_id" {
  description = "Inter-Region VPC peering connection ID, or null when disabled."
  value       = one(aws_vpc_peering_connection.inter_region[*].id)
}

output "transit_gateway_ids" {
  description = "Transit Gateway IDs in each Region, when Transit Gateway peering is enabled. Note the two gateways use different ASNs -- two gateways sharing an ASN cannot peer."
  value = local.create_tgw_peering ? {
    primary   = aws_ec2_transit_gateway.primary[0].id
    secondary = aws_ec2_transit_gateway.secondary[0].id
  } : {}
}

output "transit_gateway_peering_attachment_id" {
  description = "Transit Gateway peering attachment ID, or null. Remember that a peering attachment does NOT propagate routes -- every prefix needs a static entry on both sides."
  value       = one(aws_ec2_transit_gateway_peering_attachment.this[*].id)
}

output "instance_private_ips" {
  description = "Private addresses of the two test instances. Ping across the peering connection using these."
  value = var.enable_test_instances ? {
    primary   = module.primary_instance[0].private_ip
    secondary = module.secondary_instance[0].private_ip
  } : {}
}

output "session_manager_commands" {
  description = "Shells on each instance. Note the --region differs; a session command for one Region will not find an instance in the other."
  value = var.enable_test_instances ? {
    primary   = module.primary_instance[0].ssm_start_session_command
    secondary = module.secondary_instance[0].ssm_start_session_command
  } : {}
}

output "health_check_ids" {
  description = "Route 53 health check IDs, or empty when disabled. These are CLOUDWATCH_METRIC checks watching each instance's EC2 status check, so no inbound port has to be opened to Route 53's health checkers."
  value = var.enable_route53_health_checks && var.enable_test_instances ? {
    primary   = aws_route53_health_check.primary[0].id
    secondary = aws_route53_health_check.secondary[0].id
  } : {}
}

output "latency_tests" {
  description = "What to run from the primary instance. The round-trip time is the number that no network design can improve on."
  value = var.enable_test_instances ? {
    "1_ping_across_regions" = "ping -c 10 ${module.secondary_instance[0].private_ip}   # expect roughly 60-80 ms between Singapore and Tokyo"
    "2_ping_locally"        = "ping -c 10 ${module.primary_vpc.vpc_cidr_block == var.primary_vpc_cidr ? cidrhost(local.primary_subnets["public-a"].cidr_block, 1) : "10.90.0.1"}   # the VPC router, sub-millisecond"
    "3_traceroute"          = "traceroute -n ${module.secondary_instance[0].private_ip}   # mostly blank: the AWS backbone does not decrement TTL the way you might expect"
    "4_measure_throughput"  = "Bear in mind that data crossing this peering costs ~USD 0.02/GB in each direction. Do not run iperf3 for an hour."
  } : {}
}

output "verify_commands" {
  description = "Read-only AWS CLI commands. Note that each targets a specific Region."
  value = {
    peering_status = var.enable_vpc_peering ? "aws ec2 describe-vpc-peering-connections --region ${var.primary_region} --vpc-peering-connection-ids ${aws_vpc_peering_connection.inter_region[0].id} --query 'VpcPeeringConnections[0].{Status:Status.Code,RequesterRegion:RequesterVpcInfo.Region,AccepterRegion:AccepterVpcInfo.Region,RequesterCidr:RequesterVpcInfo.CidrBlock,AccepterCidr:AccepterVpcInfo.CidrBlock}' --output table" : "VPC peering is disabled."

    primary_routes = "aws ec2 describe-route-tables --region ${var.primary_region} --route-table-ids ${module.primary_vpc.public_route_table_id} --query 'RouteTables[0].Routes[].{Dest:DestinationCidrBlock,Peering:VpcPeeringConnectionId,TGW:TransitGatewayId,State:State}' --output table"

    secondary_routes = "aws ec2 describe-route-tables --region ${var.secondary_region} --route-table-ids ${module.secondary_vpc.public_route_table_id} --query 'RouteTables[0].Routes[].{Dest:DestinationCidrBlock,Peering:VpcPeeringConnectionId,TGW:TransitGatewayId,State:State}' --output table"

    tgw_peering_status = local.create_tgw_peering ? "aws ec2 describe-transit-gateway-peering-attachments --region ${var.primary_region} --transit-gateway-attachment-ids ${aws_ec2_transit_gateway_peering_attachment.this[0].id} --query 'TransitGatewayPeeringAttachments[0].{State:State,RequesterRegion:RequesterTgwInfo.Region,AccepterRegion:AccepterTgwInfo.Region}' --output table" : "Transit Gateway peering is disabled."

    health_checks = var.enable_route53_health_checks ? "aws route53 list-health-checks --query 'HealthChecks[].{Id:Id,Type:HealthCheckConfig.Type,Alarm:HealthCheckConfig.AlarmIdentifier.Name}' --output table" : "Health checks are disabled."

    find_leftovers_in_secondary = "aws ec2 describe-instances --region ${var.secondary_region} --filters Name=tag:Lab,Values=${local.lab_name} Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text"
  }
}
