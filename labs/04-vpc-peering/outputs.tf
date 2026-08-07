output "cost_warning" {
  description = "Standing cost of this lab as currently configured."
  value = join("\n", compact([
    format("Estimated standing cost: ~USD %.4f/hour  (~USD %.2f/day)", local.estimated_hourly_usd, local.estimated_hourly_usd * 24),
    "VPC peering connections are FREE to create and free to keep.",
    "Data across a peering connection costs about USD 0.01/GB in each direction within a Region, and nothing between instances in the same Availability Zone.",
    var.enable_test_instances ? format("Test instances: %d x t4g.nano (~USD 0.0053/hour each) + %d public IPv4 addresses (~USD 0.005/hour each).", length(local.active_vpcs), length(local.active_vpcs)) : "Test instances: disabled. This lab creates nothing chargeable.",
    "Run 'terraform destroy' when finished.",
  ]))
}

output "aws_region" {
  description = "Region this lab deployed into."
  value       = var.aws_region
}

output "vpc_ids" {
  description = "VPC IDs keyed by letter."
  value       = { for k, v in module.vpc : k => v.vpc_id }
}

output "vpc_cidrs" {
  description = "VPC CIDR blocks keyed by letter. These must never overlap: AWS refuses to peer VPCs with overlapping ranges, and there is no translation option."
  value       = { for k, v in local.active_vpcs : k => v.cidr }
}

output "peering_connection_ids" {
  description = "Peering connections keyed by pair. A peering connection is only a permission to route; without route table entries on both sides no packet moves."
  value       = { for k, v in aws_vpc_peering_connection.this : k => v.id }
}

output "peering_topology" {
  description = "Which VPCs can reach which. Peering is NOT transitive, so a pair that is not directly peered cannot communicate no matter what the route tables say."
  value = {
    connected = [for k, p in local.peerings : "${upper(p.from)} <-> ${upper(p.to)}"]
    unreachable = var.enable_vpc_c && !var.enable_b_to_c_peering ? [
      "B <-> C  (both peered with A, but peering is not transitive)",
    ] : []
    connections_needed_for_full_mesh = format(
      "%d VPCs need %d peering connections and %d route entries for a full mesh",
      length(local.active_vpcs),
      length(local.active_vpcs) * (length(local.active_vpcs) - 1) / 2,
      length(local.active_vpcs) * (length(local.active_vpcs) - 1),
    )
  }
}

output "route_table_ids" {
  description = "The public route table in each VPC, where the peering routes were added."
  value       = { for k, v in module.vpc : k => v.public_route_table_id }
}

output "instance_ids" {
  description = "Test instance IDs keyed by VPC letter."
  value       = { for k, v in module.instance : k => v.instance_id }
}

output "instance_private_ips" {
  description = "Private addresses of the test instances. These are what you ping across a peering connection -- the public addresses would go out over the internet gateway instead, which proves nothing."
  value       = { for k, v in module.instance : k => v.private_ip }
}

output "session_manager_commands" {
  description = "Commands that open a shell on each test instance."
  value       = { for k, v in module.instance : k => v.ssm_start_session_command }
}

output "connectivity_tests" {
  description = "What to run, from where, and what to expect. The last one is the lesson."
  value = var.enable_test_instances && var.enable_vpc_c ? {
    "1_from_A_ping_B" = "ping -c 3 ${module.instance["b"].private_ip}   # SUCCEEDS: A and B are directly peered"
    "2_from_A_ping_C" = "ping -c 3 ${module.instance["c"].private_ip}   # SUCCEEDS: A and C are directly peered"
    "3_from_B_ping_C" = var.enable_b_to_c_peering ? "ping -c 3 ${module.instance["c"].private_ip}   # SUCCEEDS: B and C are now directly peered too" : "ping -c 3 ${module.instance["c"].private_ip}   # FAILS: B and C are both peered with A, and peering is NOT transitive"
    "4_from_B_ping_A" = "ping -c 3 ${module.instance["a"].private_ip}   # SUCCEEDS"
  } : {}
}

output "verify_commands" {
  description = "Read-only AWS CLI commands for inspecting the peering setup."
  value = {
    list_peerings = "aws ec2 describe-vpc-peering-connections --region ${var.aws_region} --filters Name=tag:Lab,Values=${local.lab_name} --query 'VpcPeeringConnections[].{Id:VpcPeeringConnectionId,Status:Status.Code,Requester:RequesterVpcInfo.CidrBlock,Accepter:AccepterVpcInfo.CidrBlock}' --output table"

    routes_in_vpc_a = "aws ec2 describe-route-tables --route-table-ids ${module.vpc["a"].public_route_table_id} --region ${var.aws_region} --query 'RouteTables[0].Routes[].{Dest:DestinationCidrBlock,Target:VpcPeeringConnectionId,Gateway:GatewayId,State:State}' --output table"

    routes_in_vpc_b = "aws ec2 describe-route-tables --route-table-ids ${module.vpc["b"].public_route_table_id} --region ${var.aws_region} --query 'RouteTables[0].Routes[].{Dest:DestinationCidrBlock,Target:VpcPeeringConnectionId,Gateway:GatewayId,State:State}' --output table"

    dns_resolution_options = "aws ec2 describe-vpc-peering-connections --region ${var.aws_region} --filters Name=tag:Lab,Values=${local.lab_name} --query 'VpcPeeringConnections[].{Id:VpcPeeringConnectionId,RequesterDNS:RequesterVpcInfo.PeeringOptions.AllowDnsResolutionFromRemoteVpc,AccepterDNS:AccepterVpcInfo.PeeringOptions.AllowDnsResolutionFromRemoteVpc}' --output table"
  }
}
