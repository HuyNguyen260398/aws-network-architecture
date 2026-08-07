output "cost_warning" {
  description = "Standing cost of this lab as currently configured."
  value = join("\n", compact([
    format("Estimated standing cost: ~USD %.4f/hour  (~USD %.2f/day, ~USD %.2f/month)", local.estimated_hourly_usd, local.estimated_hourly_usd * 24, local.estimated_hourly_usd * 730),
    var.enable_flow_logs ? "VPC Flow Logs: ~USD 0.50/GB ingested. A quiet lab VPC produces a few MB a day -- cents. Retention is ${var.flow_log_retention_days} day(s)." : "VPC Flow Logs: disabled.",
    var.run_reachability_analysis ? "Reachability Analyzer: USD 0.10 per analysis, 2 analyses run = USD 0.20 one-off. Paths themselves are free." : "Reachability Analyzer: paths created (free), no analysis run.",
    var.enable_cloudtrail ? "CloudTrail: first copy of management events is free; you pay S3 storage only." : "CloudTrail: disabled.",
    local.create_firewall ? "AWS NETWORK FIREWALL: ~USD 0.395/hour (~USD 9.48/day, ~USD 288/month) plus ~USD 0.065/GB inspected. THE MOST EXPENSIVE RESOURCE IN THIS REPOSITORY -- destroy promptly." : "AWS Network Firewall: disabled (free).",
    "Run 'terraform destroy' when finished.",
  ]))
}

output "aws_region" {
  description = "Region this lab deployed into."
  value       = var.aws_region
}

output "vpc_id" {
  description = "ID of the lab VPC."
  value       = module.vpc.vpc_id
}

output "flow_log_group_name" {
  description = "CloudWatch log group receiving VPC Flow Logs. Records appear after the aggregation interval elapses."
  value       = one(module.flow_logs[*].log_group_name)
}

output "flow_log_tail_command" {
  description = "Streams new flow log records to your terminal. Run it in a second window while you generate traffic."
  value       = one(module.flow_logs[*].tail_command)
}

output "flow_log_queries" {
  description = "CloudWatch Logs Insights queries for the custom log format this lab uses. Paste them into the Logs Insights console against the log group above."
  value = var.enable_flow_logs ? {
    rejected_flows = join("\n", [
      "fields @timestamp, srcAddr, dstAddr, srcPort, dstPort, protocol, action",
      "| filter action = \"REJECT\"",
      "| sort @timestamp desc",
      "| limit 50",
    ])

    traffic_to_the_server = join("\n", [
      "fields @timestamp, srcAddr, dstAddr, dstPort, action, flowDirection",
      "| filter dstPort = ${local.service_port}",
      "| sort @timestamp desc",
      "| limit 50",
    ])

    top_talkers = join("\n", [
      "stats sum(bytes) as totalBytes by srcAddr, dstAddr",
      "| sort totalBytes desc",
      "| limit 20",
    ])

    original_vs_translated = join("\n", [
      "fields @timestamp, srcAddr, pktSrcAddr, dstAddr, pktDstAddr, action",
      "| filter srcAddr != pktSrcAddr or dstAddr != pktDstAddr",
      "| limit 50",
    ])
  } : {}
}

output "security_group_ids" {
  description = "The client and server security groups. Stateful, attached to ENIs, allow-only -- neither of them blocks anything in this lab."
  value = {
    client = aws_security_group.client.id
    server = aws_security_group.server.id
  }
}

output "network_acl_id" {
  description = "The private subnet's network ACL. Stateless, attached to the subnet, supports deny, evaluated in rule-number order. THIS is what blocks the lab's traffic."
  value       = aws_network_acl.private.id
}

output "nacl_block_active" {
  description = "Whether the demonstration deny rule is in place. Rule 90 denies the configured port inbound and is numbered below the allow at 100, so it is evaluated first and evaluation stops there."
  value       = var.enable_nacl_block ? "ACTIVE: rule 90 denies TCP ${var.nacl_block_port} inbound to the private subnet" : "INACTIVE: no deny rule; traffic to TCP ${var.nacl_block_port} is allowed by rule 100"
}

output "client_instance_id" {
  description = "Instance ID of the client host in the public subnet."
  value       = one(module.client[*].instance_id)
}

output "server_private_ip" {
  description = "Private address of the server host. This is the destination for every test in this lab."
  value       = one(module.server[*].private_ip)
}

output "session_manager_command" {
  description = "Opens a shell on the client host, from which the connectivity tests are run."
  value       = one(module.client[*].ssm_start_session_command)
}

output "reachability_path_ids" {
  description = "Network Insights paths. Creating a path is free; each analysis costs USD 0.10."
  value = var.enable_test_instances ? {
    "tcp_${local.service_port}" = aws_ec2_network_insights_path.client_to_server[0].id
    "tcp_22"                    = aws_ec2_network_insights_path.client_to_server_ssh[0].id
  } : {}
}

output "reachability_results" {
  description = "Whether each analysed path is reachable. When it is not, 'explanations' in the full analysis names the exact component that blocks it -- run the describe command in verify_commands to see it."
  value = var.enable_test_instances && var.run_reachability_analysis ? {
    "tcp_${local.service_port}" = aws_ec2_network_insights_analysis.client_to_server[0].path_found ? "REACHABLE" : "NOT REACHABLE -- expected while enable_nacl_block is true; the network ACL denies it"
    "tcp_22"                    = aws_ec2_network_insights_analysis.client_to_server_ssh[0].path_found ? "REACHABLE" : "NOT REACHABLE -- expected; the server security group only allows TCP ${local.service_port} from the client group"
  } : {}
}

output "firewall_id" {
  description = "AWS Network Firewall ID, or null when disabled."
  value       = one(aws_networkfirewall_firewall.this[*].id)
}

output "firewall_endpoint_id" {
  description = "VPC endpoint ID of the firewall. This is what a route table targets to send traffic through the firewall for inspection."
  value       = local.firewall_endpoint_id
}

output "firewall_alert_log_group" {
  description = "CloudWatch log group receiving Network Firewall alerts, or null when disabled. Every packet the stateful engine drops appears here with the rule that matched."
  value       = one(aws_cloudwatch_log_group.firewall_alerts[*].name)
}

output "cloudtrail_name" {
  description = "CloudTrail trail name, or null when disabled. Every VPC, route table, security group and NACL change is an EC2 API call and is recorded here."
  value       = one(aws_cloudtrail.this[*].name)
}

output "connectivity_tests" {
  description = "Run these from the client host. The contrast between them is the lab."
  value = var.enable_test_instances ? {
    "1_ping_the_server"    = "ping -c 3 ${module.server[0].private_ip}   # SUCCEEDS: neither the SG nor the NACL blocks ICMP"
    "2_reach_the_service"  = "curl -sS --max-time 8 http://${module.server[0].private_ip}:${local.service_port}/ || echo 'TIMED OUT'   # ${var.enable_nacl_block ? "TIMES OUT: the network ACL denies TCP " : "SUCCEEDS: the deny rule is off; "}${local.service_port}"
    "3_try_ssh"            = "curl -sS --max-time 8 telnet://${module.server[0].private_ip}:22 || echo 'TIMED OUT'   # TIMES OUT: the server security group only allows TCP ${local.service_port}"
    "4_watch_the_evidence" = "Run 'terraform output -raw flow_log_tail_command' in another window, then repeat test 2 and look for a REJECT record."
  } : {}
}

output "verify_commands" {
  description = "Read-only AWS CLI commands for inspecting the security and observability setup."
  value = {
    nacl_rules = "aws ec2 describe-network-acls --network-acl-ids ${aws_network_acl.private.id} --region ${var.aws_region} --query 'NetworkAcls[0].Entries[].{Num:RuleNumber,Egress:Egress,Proto:Protocol,Action:RuleAction,CIDR:CidrBlock,Ports:PortRange}' --output table"

    security_group_rules = "aws ec2 describe-security-group-rules --region ${var.aws_region} --filters Name=group-id,Values=${aws_security_group.server.id} --query 'SecurityGroupRules[].{Egress:IsEgress,Proto:IpProtocol,From:FromPort,To:ToPort,CIDR:CidrIpv4,SourceSG:ReferencedGroupInfo.GroupId}' --output table"

    reachability_explanation = var.enable_test_instances && var.run_reachability_analysis ? "aws ec2 describe-network-insights-analyses --network-insights-analysis-ids ${aws_ec2_network_insights_analysis.client_to_server[0].id} --region ${var.aws_region} --query 'NetworkInsightsAnalyses[0].{Found:NetworkPathFound,Explanations:Explanations}' --output json" : "Set run_reachability_analysis = true."

    rerun_analysis = var.enable_test_instances ? "aws ec2 start-network-insights-analysis --network-insights-path-id ${aws_ec2_network_insights_path.client_to_server[0].id} --region ${var.aws_region}   # costs USD 0.10 each time" : ""

    recent_network_changes = var.enable_cloudtrail ? "aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=AuthorizeSecurityGroupIngress --region ${var.aws_region} --max-results 10 --query 'Events[].{Time:EventTime,User:Username,Event:EventName}' --output table" : "Set enable_cloudtrail = true, or query an existing trail."

    firewall_status = local.create_firewall ? "aws network-firewall describe-firewall --firewall-name ${aws_networkfirewall_firewall.this[0].name} --region ${var.aws_region} --query 'FirewallStatus' --output json" : "AWS Network Firewall is disabled."
  }
}
