output "cost_warning" {
  description = "Standing cost of this lab as currently configured."
  value = join("\n", compact([
    format("Estimated standing cost: ~USD %.4f/hour  (~USD %.2f/day, ~USD %.2f/month)", local.estimated_hourly_usd, local.estimated_hourly_usd * 24, local.estimated_hourly_usd * 730),
    "Free: customer gateway, virtual private gateway, Direct Connect gateway (with no virtual interfaces).",
    local.create_vpn ? "Site-to-Site VPN connection: ~USD 0.05/hour (~USD 36/month). BILLED FROM CREATION, whether or not a tunnel ever comes up." : "Site-to-Site VPN: disabled (free).",
    local.create_tgw ? "Transit Gateway attachments: 2 at ~USD 0.05/hour each (VPC + VPN)." : "",
    local.create_onprem ? "Simulated on-premises router: t4g.small ~USD 0.0212/hour + Elastic IP ~USD 0.005/hour." : "",
    var.enable_direct_connect_gateway ? "Direct Connect gateway: FREE while no virtual interface is attached." : "",
    "Run 'terraform destroy' when finished.",
  ]))
}

output "aws_region" {
  description = "Region this lab deployed into."
  value       = var.aws_region
}

output "aws_vpc_id" {
  description = "ID of the AWS-side VPC."
  value       = module.aws_vpc.vpc_id
}

output "aws_vpc_cidr" {
  description = "CIDR of the AWS-side VPC. This is the prefix advertised toward on-premises."
  value       = var.aws_vpc_cidr
}

output "on_premises_cidr" {
  description = "CIDR representing the on-premises network. Must never overlap the AWS side."
  value       = var.on_premises_cidr
}

output "vpn_gateway_id" {
  description = "Virtual private gateway ID, or null when the VPN terminates on a Transit Gateway instead. Free either way."
  value       = one(aws_vpn_gateway.this[*].id)
}

output "transit_gateway_id" {
  description = "Transit Gateway ID when enable_transit_gateway_attachment is true. One VPN attachment here serves every VPC attached to the gateway, which a virtual private gateway cannot do."
  value       = one(aws_ec2_transit_gateway.this[*].id)
}

output "customer_gateway_id" {
  description = "Customer gateway ID. This is only a record of your on-premises device's public IP and BGP ASN -- creating it does nothing and costs nothing."
  value       = one(aws_customer_gateway.this[*].id)
}

output "customer_gateway_ip" {
  description = "Public IP AWS will negotiate with. Either the simulated router's Elastic IP or the address you supplied."
  value       = local.customer_gateway_ip
}

output "vpn_connection_id" {
  description = "Site-to-Site VPN connection ID, or null when disabled."
  value       = one(aws_vpn_connection.this[*].id)
}

output "vpn_tunnel_outside_addresses" {
  description = "Public addresses of the two AWS VPN endpoints. AWS always provisions two tunnels, in two Availability Zones -- this is not optional and not extra cost."
  value = local.create_vpn ? {
    tunnel1 = aws_vpn_connection.this[0].tunnel1_address
    tunnel2 = aws_vpn_connection.this[0].tunnel2_address
  } : {}
}

output "vpn_tunnel_inside_cidrs" {
  description = "The /30 link networks inside each tunnel. With BGP these carry the BGP session; with static routing they are unused."
  value = local.create_vpn ? {
    tunnel1 = aws_vpn_connection.this[0].tunnel1_inside_cidr
    tunnel2 = aws_vpn_connection.this[0].tunnel2_inside_cidr
  } : {}
}

output "vpn_preshared_keys" {
  description = "Pre-shared keys for the two tunnels. SENSITIVE: anyone holding these can impersonate the on-premises end. They are stored in Terraform state; keep the state bucket locked down."
  value = local.create_vpn ? {
    tunnel1 = aws_vpn_connection.this[0].tunnel1_preshared_key
    tunnel2 = aws_vpn_connection.this[0].tunnel2_preshared_key
  } : {}
  sensitive = true
}

output "routing_mode" {
  description = "Static or BGP, and what that implies for failover."
  value       = local.static_routing ? "STATIC. AWS was told explicitly that ${var.on_premises_cidr} is reachable over the tunnel. Only one tunnel carries traffic at a time; failover to the second happens when dead peer detection notices the first has gone." : "BGP. The on-premises router advertises its prefixes and learns yours dynamically. Both tunnels can carry traffic simultaneously with ECMP, and failover takes seconds with no route table edits."
}

output "direct_connect_gateway_id" {
  description = "Direct Connect gateway ID, or null when disabled. A DX gateway with no virtual interfaces attached is free. The physical connection and the virtual interfaces cannot be created from Terraform alone -- see the README."
  value       = one(aws_dx_gateway.this[*].id)
}

output "on_premises_router_id" {
  description = "Instance ID of the simulated on-premises router, or null when the simulation is disabled."
  value       = one(module.on_premises_router[*].instance_id)
}

output "on_premises_router_public_ip" {
  description = "Elastic IP of the simulated router. This is the address recorded in the customer gateway and the identity the router presents during IKE."
  value       = one(aws_eip.on_premises[*].public_ip)
}

output "aws_instance_private_ip" {
  description = "Private address of the AWS-side test host. Ping this from the on-premises router to prove the tunnel carries traffic."
  value       = one(module.aws_instance[*].private_ip)
}

output "session_manager_commands" {
  description = "Shells on the two hosts. The on-premises router is reached over its own VPC's internet gateway, not over the tunnel."
  value = merge(
    var.enable_test_instance ? { aws_host = module.aws_instance[0].ssm_start_session_command } : {},
    local.create_onprem ? { on_premises_router = module.on_premises_router[0].ssm_start_session_command } : {},
  )
}

output "tunnel_tests" {
  description = "How to check whether the tunnels actually came up, and whether they carry traffic."
  value = local.create_vpn ? {
    "1_tunnel_state_from_aws" = "aws ec2 describe-vpn-connections --vpn-connection-ids ${aws_vpn_connection.this[0].id} --region ${var.aws_region} --query 'VpnConnections[0].VgwTelemetry[].{Outside:OutsideIpAddress,Status:Status,Message:StatusMessage,Routes:AcceptedRouteCount}' --output table"

    "2_router_status" = local.create_onprem ? "Run on the on-premises router:  sudo tunnel-status" : "Run the equivalent on your own device."

    "3_router_logs" = local.create_onprem ? "Run on the on-premises router:  sudo journalctl -u ipsec -n 100 --no-pager  and  sudo cat /var/log/lab07-router-setup.log" : "Check your device's IKE logs."

    "4_ping_across" = var.enable_test_instance && local.create_onprem ? "Run on the on-premises router:  ping -c 5 ${module.aws_instance[0].private_ip}" : "Ping the AWS-side private address from your on-premises network."

    "5_vpc_route_table" = "aws ec2 describe-route-tables --route-table-ids ${module.aws_vpc.public_route_table_id} --region ${var.aws_region} --query 'RouteTables[0].Routes[].{Dest:DestinationCidrBlock,Gateway:GatewayId,Origin:Origin,State:State}' --output table"

    "6_aws_sample_config" = "aws ec2 get-vpn-connection-device-sample-configuration --vpn-connection-id ${aws_vpn_connection.this[0].id} --vpn-connection-device-type-id <type> --region ${var.aws_region} --output text   # list types with: aws ec2 get-vpn-connection-device-types"
  } : {}
}

output "verify_commands" {
  description = "Read-only AWS CLI commands for inspecting the hybrid setup."
  value = {
    vpn_connections = "aws ec2 describe-vpn-connections --region ${var.aws_region} --filters Name=tag:Lab,Values=${local.lab_name} --query 'VpnConnections[].{Id:VpnConnectionId,State:State,Static:Options.StaticRoutesOnly,CGW:CustomerGatewayId}' --output table"

    customer_gateways = "aws ec2 describe-customer-gateways --region ${var.aws_region} --filters Name=tag:Lab,Values=${local.lab_name} --query 'CustomerGateways[].{Id:CustomerGatewayId,IP:IpAddress,ASN:BgpAsn,State:State}' --output table"

    vpn_gateways = "aws ec2 describe-vpn-gateways --region ${var.aws_region} --filters Name=tag:Lab,Values=${local.lab_name} --query 'VpnGateways[].{Id:VpnGatewayId,State:State,ASN:AmazonSideAsn}' --output table"

    dx_gateways = "aws directconnect describe-direct-connect-gateways --region ${var.aws_region} --query 'directConnectGateways[].{Id:directConnectGatewayId,Name:directConnectGatewayName,ASN:amazonSideAsn,State:directConnectGatewayState}' --output table"

    dx_connections = "aws directconnect describe-connections --region ${var.aws_region} --query 'connections' --output json   # expect [] -- a physical circuit cannot be created from Terraform"
  }
}
