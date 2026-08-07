output "cost_warning" {
  description = "Standing cost of this lab as currently configured. Read this before walking away from it."
  value = join("\n", compact([
    format("Estimated standing cost: ~USD %.4f/hour  (~USD %.2f/day, ~USD %.2f/month)", local.estimated_hourly_usd, local.estimated_hourly_usd * 24, local.estimated_hourly_usd * 730),
    local.nat_gateway_mode == "none" ? "NAT gateway: DISABLED (free). Private subnets have no outbound internet access." : format("NAT gateway: %d gateway(s) at ~USD 0.059/hour EACH, plus ~USD 0.059/GB processed. THIS IS THE EXPENSIVE PART.", local.nat_gateway_mode == "per_az" ? var.az_count : 1),
    var.enable_test_instances ? "Test instances: 2 x t4g.nano (~USD 0.0053/hour each) + 1 public IPv4 address (~USD 0.005/hour)." : "Test instances: disabled.",
    local.enable_eoigw ? "Egress-only internet gateway: enabled and FREE. IPv6 outbound works at no cost." : "",
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

output "vpc_cidr_block" {
  description = "IPv4 CIDR of the VPC."
  value       = module.vpc.vpc_cidr_block
}

output "public_subnets" {
  description = "Public subnets. Public because their route table has 0.0.0.0/0 pointing at the internet gateway, and because map_public_ip_on_launch is on."
  value       = module.vpc.public_subnets
}

output "private_subnets" {
  description = "Private subnets. Their outbound reachability depends entirely on whether a NAT gateway route exists."
  value       = module.vpc.private_subnets
}

output "public_route_table_id" {
  description = "Route table shared by the public subnets."
  value       = module.vpc.public_route_table_id
}

output "private_route_table_ids" {
  description = "Private route tables keyed by Availability Zone index. With NAT disabled these contain only the local route."
  value       = module.vpc.private_route_table_ids
}

output "nat_gateway_ids" {
  description = "NAT gateways keyed by Availability Zone index. Empty when enable_nat_gateway is false."
  value       = module.vpc.nat_gateway_ids
}

output "nat_gateway_public_ips" {
  description = "Public addresses of the NAT gateways. This is the source address an external service sees for traffic that originated in a private subnet -- run 'curl ifconfig.me' from the private instance and compare."
  value       = module.vpc.nat_gateway_public_ips
}

output "egress_only_internet_gateway_id" {
  description = "Egress-only internet gateway for IPv6, or null. Free."
  value       = module.vpc.egress_only_internet_gateway_id
}

output "public_instance_id" {
  description = "Instance ID of the host in the public subnet."
  value       = one(module.public_instance[*].instance_id)
}

output "private_instance_id" {
  description = "Instance ID of the host in the private subnet."
  value       = one(module.private_instance[*].instance_id)
}

output "public_instance_private_ip" {
  description = "Private address of the public-subnet instance. Ping this from the private instance to prove that intra-VPC routing needs no gateway at all."
  value       = one(module.public_instance[*].private_ip)
}

output "private_instance_private_ip" {
  description = "Private address of the private-subnet instance."
  value       = one(module.private_instance[*].private_ip)
}

output "public_instance_public_ip" {
  description = "Public address of the public-subnet instance, assigned because its subnet has map_public_ip_on_launch enabled."
  value       = one(module.public_instance[*].public_ip)
}

output "session_manager_commands" {
  description = "Commands that open a shell on each instance. The private one only works when enable_nat_gateway is true -- without a route to the internet its SSM agent can never register."
  value = var.enable_test_instances ? {
    public  = module.public_instance[0].ssm_start_session_command
    private = "${module.private_instance[0].ssm_start_session_command}   # fails with TargetNotConnected unless enable_nat_gateway = true"
  } : {}
}

output "verify_commands" {
  description = "Read-only AWS CLI commands for checking what was built."
  value = {
    which_instances_registered_with_ssm = "aws ssm describe-instance-information --region ${var.aws_region} --query 'InstanceInformationList[].{Id:InstanceId,Ping:PingStatus,IP:IPAddress}' --output table"

    public_route_table = "aws ec2 describe-route-tables --route-table-ids ${module.vpc.public_route_table_id} --region ${var.aws_region} --query 'RouteTables[0].Routes' --output table"

    private_route_tables = "aws ec2 describe-route-tables --filters Name=vpc-id,Values=${module.vpc.vpc_id} Name=tag:Name,Values='*rt-private*' --region ${var.aws_region} --query 'RouteTables[].{Name:Tags[?Key==`Name`]|[0].Value,Routes:Routes[].{Dest:DestinationCidrBlock,NAT:NatGatewayId,GW:GatewayId}}' --output json"

    nat_gateways = "aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=${module.vpc.vpc_id} --region ${var.aws_region} --query 'NatGateways[].{Id:NatGatewayId,State:State,Subnet:SubnetId,PublicIP:NatGatewayAddresses[0].PublicIp}' --output table"

    subnets_and_auto_assign = "aws ec2 describe-subnets --filters Name=vpc-id,Values=${module.vpc.vpc_id} --region ${var.aws_region} --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,CIDR:CidrBlock,AutoPublicIP:MapPublicIpOnLaunch}' --output table"
  }
}
