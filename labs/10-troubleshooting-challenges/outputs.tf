output "warning" {
  description = "What this lab is."
  value       = "THIS LAB DEPLOYS DELIBERATELY BROKEN INFRASTRUCTURE. Every resource is tagged Warning=intentionally-misconfigured. Nothing is reachable from the internet except through Session Manager, and every fault is confined to this lab's own VPCs."
}

output "cost_warning" {
  description = "Standing cost of this lab as currently configured."
  value = join("\n", compact([
    format("Estimated standing cost: ~USD %.4f/hour  (~USD %.2f/day)", local.estimated_hourly_usd, local.estimated_hourly_usd * 24),
    var.enable_test_instances ? "Test instances: t4g.nano hosts plus public IPv4 addresses." : "Test instances: disabled.",
    local.need_flow_logs ? "VPC Flow Logs: ~USD 0.50/GB ingested. Cents for a lab, with ${var.flow_log_retention_days}-day retention." : "",
    "Nothing in this lab is billed by the hour beyond the instances. Destroy it when you are done anyway.",
  ]))
}

output "aws_region" {
  description = "Region this lab deployed into."
  value       = var.aws_region
}

output "active_challenges" {
  description = "The scenarios currently deployed, with the symptom you are investigating. Read HINTS.md only when stuck; SOLUTIONS.md gives the answer away."
  value       = local.active_briefs
}

output "vpc_ids" {
  description = "VPCs created for the enabled challenges."
  value = merge(
    { base = module.base_vpc.vpc_id },
    local.need_peer_vpc ? { peer = module.peer_vpc[0].vpc_id } : {},
    local.need_overlap_vpc ? { overlap = module.overlap_vpc[0].vpc_id } : {},
    local.c.broken_dns ? { dns = module.dns_vpc[0].vpc_id } : {},
  )
}

output "vpc_cidrs" {
  description = "VPC CIDRs. Worth reading carefully when the overlapping-cidr challenge is enabled."
  value = merge(
    { base = var.base_vpc_cidr },
    local.need_peer_vpc ? { peer = var.peer_vpc_cidr } : {},
    local.need_overlap_vpc ? { overlap = var.base_vpc_cidr } : {},
    local.c.broken_dns ? { dns = "10.102.0.0/16" } : {},
  )
}

output "client_instance_id" {
  description = "Client host in the base VPC's public subnet. Most investigations start here."
  value       = one(module.client[*].instance_id)
}

output "server_private_ip" {
  description = "Private address of the server host, listening on TCP 8080."
  value       = one(module.server[*].private_ip)
}

output "peer_instance_private_ip" {
  description = "Private address of the instance in the peer VPC, when a routing challenge created it."
  value       = one(module.peer_instance[*].private_ip)
}

output "session_manager_commands" {
  description = "Shells on each host. Note that the server sits in a private subnet with no NAT gateway and no VPC endpoints, so Session Manager cannot reach it -- use the client host and test toward the server."
  value = merge(
    var.enable_test_instances ? { client = module.client[0].ssm_start_session_command } : {},
    local.need_peer_vpc && var.enable_test_instances ? { peer = module.peer_instance[0].ssm_start_session_command } : {},
  )
}

output "s3_bucket_name" {
  description = "Bucket used by the endpoint challenges, or null."
  value       = one(aws_s3_bucket.challenge[*].id)
}

output "flow_log_group_name" {
  description = "CloudWatch log group receiving flow logs, when the flow-log-rejects challenge is enabled. This is where the evidence is."
  value       = one(module.flow_logs[*].log_group_name)
}

output "flow_log_tail_command" {
  description = "Streams flow log records as they arrive. Run it in a second window, then generate the failing traffic."
  value       = one(module.flow_logs[*].tail_command)
}

output "investigation_starters" {
  description = "Read-only commands that are usually the right first move. They tell you nothing you could not find yourself -- they just save typing."
  value = {
    all_route_tables = "aws ec2 describe-route-tables --region ${var.aws_region} --filters Name=tag:Lab,Values=${local.lab_name} --query 'RouteTables[].{Name:Tags[?Key==`Name`]|[0].Value,Id:RouteTableId,Routes:Routes[].{Dest:DestinationCidrBlock,Target:GatewayId,Peering:VpcPeeringConnectionId,PrefixList:DestinationPrefixListId,State:State}}' --output json"

    all_security_group_rules = "aws ec2 describe-security-group-rules --region ${var.aws_region} --filters Name=group-id,Values=${aws_security_group.server.id} --query 'SecurityGroupRules[].{Egress:IsEgress,Proto:IpProtocol,From:FromPort,To:ToPort,CIDR:CidrIpv4,SourceSG:ReferencedGroupInfo.GroupId}' --output table"

    security_group_ids = "echo 'client=${aws_security_group.client.id} server=${aws_security_group.server.id}'   # compare these against the SourceSG column above"

    network_acls = "aws ec2 describe-network-acls --region ${var.aws_region} --filters Name=vpc-id,Values=${module.base_vpc.vpc_id} --query 'NetworkAcls[].{Id:NetworkAclId,Default:IsDefault,Entries:Entries[].{Num:RuleNumber,Egress:Egress,Action:RuleAction,Proto:Protocol,CIDR:CidrBlock,Ports:PortRange}}' --output json"

    vpc_dns_attributes = "for a in enableDnsSupport enableDnsHostnames; do aws ec2 describe-vpc-attribute --region ${var.aws_region} --vpc-id ${module.base_vpc.vpc_id} --attribute $a --output json; done"

    peering_connections = "aws ec2 describe-vpc-peering-connections --region ${var.aws_region} --filters Name=tag:Lab,Values=${local.lab_name} --query 'VpcPeeringConnections[].{Id:VpcPeeringConnectionId,Status:Status.Code,Requester:RequesterVpcInfo.CidrBlock,Accepter:AccepterVpcInfo.CidrBlock}' --output table"

    vpc_endpoints = "aws ec2 describe-vpc-endpoints --region ${var.aws_region} --filters Name=vpc-id,Values=${module.base_vpc.vpc_id} --query 'VpcEndpoints[].{Service:ServiceName,Type:VpcEndpointType,State:State,RouteTables:RouteTableIds,Policy:PolicyDocument}' --output json"

    reachability_analyzer = "aws ec2 create-network-insights-path --region ${var.aws_region} --source <eni-id> --destination <eni-id> --protocol tcp --destination-port 8080   # then start-network-insights-analysis, USD 0.10 each"
  }
}
