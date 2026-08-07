output "cost_warning" {
  description = "What this lab costs while it is running."
  value       = "This lab creates NO chargeable resources. VPCs, subnets, route tables, internet gateways, security groups and network ACLs are all free. Destroy it anyway when you are finished -- the account-level limit is 5 VPCs per Region by default."
}

output "aws_region" {
  description = "Region this lab deployed into. Handy for building AWS CLI commands: aws ec2 ... --region $(terraform output -raw aws_region)."
  value       = var.aws_region
}

output "vpc_id" {
  description = "ID of the lab VPC."
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "IPv4 CIDR of the VPC. Every subnet below is a slice of this range."
  value       = module.vpc.vpc_cidr_block
}

output "vpc_ipv6_cidr_block" {
  description = "Amazon-provided IPv6 /56, or null when enable_ipv6 is false. You do not get to choose this range, which is why IPv6 never has the overlapping-CIDR problem IPv4 designs suffer from."
  value       = module.vpc.vpc_ipv6_cidr_block
}

output "availability_zones" {
  description = "Availability Zones the subnets were placed in. These names are account-specific: your ap-southeast-1a is physically a different zone from someone else's."
  value       = module.vpc.availability_zones
}

output "public_subnets" {
  description = "Public subnets, with their CIDR, IPv6 prefix and Availability Zone. They are public because the route table they are associated with sends 0.0.0.0/0 to the internet gateway -- not because of their name."
  value       = module.vpc.public_subnets
}

output "private_subnets" {
  description = "Private subnets. These have no default route at all in this lab, which makes them fully isolated: they can reach other subnets in the VPC and nothing else."
  value       = module.vpc.private_subnets
}

output "internet_gateway_id" {
  description = "ID of the internet gateway. Free to create and free to keep."
  value       = module.vpc.internet_gateway_id
}

output "public_route_table_id" {
  description = "Route table shared by the public subnets. Inspect it to see the 0.0.0.0/0 entry that makes those subnets public."
  value       = module.vpc.public_route_table_id
}

output "private_route_table_ids" {
  description = "Private route tables, keyed by Availability Zone index. These contain only the VPC-local route."
  value       = module.vpc.private_route_table_ids
}

output "web_security_group_id" {
  description = "Stateful, instance-level filter allowing HTTPS inbound from anywhere."
  value       = aws_security_group.web.id
}

output "app_security_group_id" {
  description = "Stateful filter allowing TCP 8080 from the web security group, demonstrating security group referencing."
  value       = aws_security_group.app.id
}

output "private_network_acl_id" {
  description = "Stateless, subnet-level filter on the private subnets. Unlike a security group it supports deny rules and evaluates rules in numbered order."
  value       = aws_network_acl.private.id
}

output "verify_commands" {
  description = "Copy-paste AWS CLI commands that read back what Terraform created. All of these are read-only."
  value = {
    show_vpc = "aws ec2 describe-vpcs --vpc-ids ${module.vpc.vpc_id} --region ${var.aws_region} --output table"

    show_subnets = "aws ec2 describe-subnets --filters Name=vpc-id,Values=${module.vpc.vpc_id} --region ${var.aws_region} --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,CIDR:CidrBlock,AZ:AvailabilityZone,Free:AvailableIpAddressCount}' --output table"

    show_route_tables = "aws ec2 describe-route-tables --filters Name=vpc-id,Values=${module.vpc.vpc_id} --region ${var.aws_region} --query 'RouteTables[].{Name:Tags[?Key==`Name`]|[0].Value,Routes:Routes[].{Dest:DestinationCidrBlock,Target:GatewayId}}' --output json"

    prove_public_route = "aws ec2 describe-route-tables --route-table-ids ${module.vpc.public_route_table_id} --region ${var.aws_region} --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`]' --output json"

    show_network_acl = "aws ec2 describe-network-acls --network-acl-ids ${aws_network_acl.private.id} --region ${var.aws_region} --query 'NetworkAcls[0].Entries' --output table"

    show_security_groups = "aws ec2 describe-security-groups --filters Name=vpc-id,Values=${module.vpc.vpc_id} --region ${var.aws_region} --query 'SecurityGroups[].{Name:GroupName,Id:GroupId,Ingress:length(IpPermissions)}' --output table"
  }
}

output "usable_addresses_per_subnet" {
  description = "Usable IPv4 addresses in each subnet after AWS's five reserved addresses. AWS reserves the network address, the VPC router (.1), the DNS resolver (.2), one for future use (.3), and the broadcast address."
  value = {
    for k, v in merge(module.vpc.public_subnets, module.vpc.private_subnets) :
    k => format("%s -> %d usable (of %d total; AWS reserves 5)",
      v.cidr_block,
      pow(2, 32 - tonumber(split("/", v.cidr_block)[1])) - 5,
      pow(2, 32 - tonumber(split("/", v.cidr_block)[1])),
    )
  }
}
