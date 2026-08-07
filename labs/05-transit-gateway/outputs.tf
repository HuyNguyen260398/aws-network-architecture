output "cost_warning" {
  description = "Standing cost of this lab as currently configured. Read this before walking away."
  value = join("\n", compact([
    format("Estimated standing cost: ~USD %.4f/hour  (~USD %.2f/day, ~USD %.2f/month)", local.estimated_hourly_usd, local.estimated_hourly_usd * 24, local.estimated_hourly_usd * 730),
    local.create_tgw ? format("Transit Gateway ATTACHMENTS: %d at ~USD 0.05/hour EACH (~USD %.0f/month total) plus ~USD 0.02/GB processed. The gateway itself is free; the attachments are the charge.", local.attachment_count, local.attachment_count * 36.5) : "Transit Gateway: DISABLED. Three free, unconnected VPCs only.",
    var.enable_test_instances ? "Test instances: 3 x t4g.nano + 3 public IPv4 addresses, ~USD 0.031/hour." : "Test instances: disabled.",
    local.create_tgw ? "THIS IS THE MOST EXPENSIVE LAB IN THE REPOSITORY. Destroy it the same day." : "",
  ]))
}

output "aws_region" {
  description = "Region this lab deployed into."
  value       = var.aws_region
}

output "transit_gateway_id" {
  description = "ID of the Transit Gateway, or null when disabled."
  value       = one(aws_ec2_transit_gateway.this[*].id)
}

output "transit_gateway_asn" {
  description = "Amazon-side BGP ASN of the Transit Gateway. Relevant when attaching a Site-to-Site VPN with BGP in lab 07 -- the on-premises router must use a different ASN."
  value       = one(aws_ec2_transit_gateway.this[*].amazon_side_asn)
}

output "vpc_ids" {
  description = "Spoke VPC IDs keyed by name."
  value       = { for k, v in module.vpc : k => v.vpc_id }
}

output "vpc_cidrs" {
  description = "Spoke VPC CIDRs. All three sit inside supernet_cidr, so each VPC needs only one route pointing at the Transit Gateway."
  value       = { for k, v in local.spokes : k => v.cidr }
}

output "attachment_ids" {
  description = "Transit Gateway VPC attachment IDs keyed by spoke. Each of these is billed at ~USD 0.05/hour."
  value       = { for k, v in aws_ec2_transit_gateway_vpc_attachment.this : k => v.id }
}

output "route_table_ids" {
  description = "Transit Gateway route tables. 'spoke' is consulted by prod and dev; 'shared' is consulted by shared-services."
  value = local.create_tgw ? {
    spoke  = aws_ec2_transit_gateway_route_table.spoke[0].id
    shared = aws_ec2_transit_gateway_route_table.shared[0].id
  } : {}
}

output "segmentation_matrix" {
  description = "Who can reach whom, and why. This is what the Transit Gateway route tables produce."
  value = local.create_tgw ? {
    "prod -> shared"             = "ALLOWED  (spoke route table has learned the shared VPC via propagation)"
    "dev -> shared"              = "ALLOWED  (same)"
    "shared -> prod"             = "ALLOWED  (shared route table has learned prod)"
    "shared -> dev"              = "ALLOWED  (shared route table has learned dev)"
    "prod -> dev"                = var.allow_dev_to_prod ? "ALLOWED  (allow_dev_to_prod added a propagation -- segmentation is now collapsed)" : "BLOCKED  (the spoke route table contains no route to dev; the packet is dropped at the gateway)"
    "dev -> prod"                = var.allow_dev_to_prod ? "ALLOWED  (allow_dev_to_prod added a propagation)" : "BLOCKED  (same table, same reason)"
    "* -> ${var.blackhole_cidr}" = "BLACKHOLED  (a static blackhole route silently discards it -- not an error, and invisible without flow logs)"
  } : {}
}

output "association_vs_propagation" {
  description = "The distinction that causes more Transit Gateway confusion than anything else."
  value = {
    association = "Which ONE route table an attachment consults when SENDING traffic. Exactly one per attachment."
    propagation = "Which route tables LEARN this attachment's VPC CIDR. Any number per attachment, and completely independent of the association."
    consequence = "Association without propagation means you can send but nobody can reply. Propagation without association means others can reach you but you cannot initiate. Neither produces an error -- both produce one-way connectivity."
  }
}

output "instance_private_ips" {
  description = "Private addresses of the test instances. Ping these across the Transit Gateway."
  value       = { for k, v in module.instance : k => v.private_ip }
}

output "session_manager_commands" {
  description = "Commands that open a shell on each test instance."
  value       = { for k, v in module.instance : k => v.ssm_start_session_command }
}

output "connectivity_tests" {
  description = "What to run, from where, and what to expect."
  value = var.enable_test_instances && local.create_tgw ? {
    "from_prod_ping_shared" = "ping -c 3 ${module.instance["shared"].private_ip}   # SUCCEEDS"
    "from_dev_ping_shared"  = "ping -c 3 ${module.instance["shared"].private_ip}   # SUCCEEDS"
    "from_prod_ping_dev"    = var.allow_dev_to_prod ? "ping -c 3 ${module.instance["dev"].private_ip}   # SUCCEEDS -- segmentation collapsed" : "ping -c 3 ${module.instance["dev"].private_ip}   # FAILS -- no route in the spoke table"
    "from_shared_ping_prod" = "ping -c 3 ${module.instance["prod"].private_ip}   # SUCCEEDS"
    "blackhole_test"        = "ping -c 3 ${cidrhost(var.blackhole_cidr, 10)}   # FAILS silently -- blackhole route at the gateway"
  } : {}
}

output "verify_commands" {
  description = "Read-only AWS CLI commands for inspecting the Transit Gateway."
  value = local.create_tgw ? {
    list_attachments = "aws ec2 describe-transit-gateway-attachments --region ${var.aws_region} --filters Name=transit-gateway-id,Values=${aws_ec2_transit_gateway.this[0].id} --query 'TransitGatewayAttachments[].{Id:TransitGatewayAttachmentId,Type:ResourceType,Resource:ResourceId,State:State}' --output table"

    spoke_route_table = "aws ec2 search-transit-gateway-routes --region ${var.aws_region} --transit-gateway-route-table-id ${aws_ec2_transit_gateway_route_table.spoke[0].id} --filters Name=state,Values=active,blackhole --query 'Routes[].{CIDR:DestinationCidrBlock,Type:Type,State:State,Attachment:TransitGatewayAttachments[0].ResourceId}' --output table"

    shared_route_table = "aws ec2 search-transit-gateway-routes --region ${var.aws_region} --transit-gateway-route-table-id ${aws_ec2_transit_gateway_route_table.shared[0].id} --filters Name=state,Values=active,blackhole --query 'Routes[].{CIDR:DestinationCidrBlock,Type:Type,State:State,Attachment:TransitGatewayAttachments[0].ResourceId}' --output table"

    associations = "aws ec2 get-transit-gateway-route-table-associations --region ${var.aws_region} --transit-gateway-route-table-id ${aws_ec2_transit_gateway_route_table.spoke[0].id} --query 'Associations[].{Attachment:TransitGatewayAttachmentId,Resource:ResourceId,State:State}' --output table"

    propagations = "aws ec2 get-transit-gateway-route-table-propagations --region ${var.aws_region} --transit-gateway-route-table-id ${aws_ec2_transit_gateway_route_table.spoke[0].id} --query 'TransitGatewayRouteTablePropagations[].{Attachment:TransitGatewayAttachmentId,Resource:ResourceId,State:State}' --output table"
  } : {}
}
