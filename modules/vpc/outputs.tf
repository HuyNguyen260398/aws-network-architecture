output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_arn" {
  description = "ARN of the VPC, for resource policies and Resource Access Manager shares."
  value       = aws_vpc.this.arn
}

output "vpc_cidr_block" {
  description = "IPv4 CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "vpc_ipv6_cidr_block" {
  description = "Amazon-provided IPv6 /56 assigned to the VPC, or null when enable_ipv6 is false."
  value       = var.enable_ipv6 ? aws_vpc.this.ipv6_cidr_block : null
}

output "default_security_group_id" {
  description = "ID of the VPC's default security group. When manage_default_security_group is true this group has no rules and should never be attached to anything."
  value       = aws_vpc.this.default_security_group_id
}

output "availability_zones" {
  description = "Availability Zone names resolved for this VPC, in the order that az_index refers to."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Map of public subnet key to subnet ID."
  value       = { for k, v in aws_subnet.public : k => v.id }
}

output "private_subnet_ids" {
  description = "Map of private subnet key to subnet ID."
  value       = { for k, v in aws_subnet.private : k => v.id }
}

output "public_subnet_ids_list" {
  description = "Public subnet IDs as a list, sorted by subnet key, for arguments that require a list such as load balancer subnet mappings."
  value       = [for k in sort(keys(aws_subnet.public)) : aws_subnet.public[k].id]
}

output "private_subnet_ids_list" {
  description = "Private subnet IDs as a list, sorted by subnet key."
  value       = [for k in sort(keys(aws_subnet.private)) : aws_subnet.private[k].id]
}

output "public_subnets" {
  description = "Full detail for each public subnet: id, cidr_block, ipv6_cidr_block, availability_zone and arn."
  value = {
    for k, v in aws_subnet.public : k => {
      id                = v.id
      arn               = v.arn
      cidr_block        = v.cidr_block
      ipv6_cidr_block   = v.ipv6_cidr_block
      availability_zone = v.availability_zone
    }
  }
}

output "private_subnets" {
  description = "Full detail for each private subnet: id, cidr_block, ipv6_cidr_block, availability_zone and arn."
  value = {
    for k, v in aws_subnet.private : k => {
      id                = v.id
      arn               = v.arn
      cidr_block        = v.cidr_block
      ipv6_cidr_block   = v.ipv6_cidr_block
      availability_zone = v.availability_zone
    }
  }
}

output "internet_gateway_id" {
  description = "ID of the internet gateway, or null when create_internet_gateway is false."
  value       = one(aws_internet_gateway.this[*].id)
}

output "egress_only_internet_gateway_id" {
  description = "ID of the egress-only internet gateway, or null when it was not created."
  value       = one(aws_egress_only_internet_gateway.this[*].id)
}

output "public_route_table_id" {
  description = "ID of the shared public route table, or null when there are no public subnets. Attach VPC endpoints or peering routes here."
  value       = one(aws_route_table.public[*].id)
}

output "private_route_table_ids" {
  description = "Map of Availability Zone index (as a string) to private route table ID. Use these when adding peering, Transit Gateway, or gateway endpoint routes."
  value       = { for k, v in aws_route_table.private : k => v.id }
}

output "all_route_table_ids" {
  description = "Every route table this module manages, public and private, as a list. Convenient for attaching an S3 gateway endpoint to all of them at once."
  value       = concat(aws_route_table.public[*].id, [for k in sort(keys(aws_route_table.private)) : aws_route_table.private[k].id])
}

output "nat_gateway_ids" {
  description = "Map of Availability Zone index (as a string) to NAT gateway ID. Empty when nat_gateway_mode is 'none'."
  value       = { for k, v in aws_nat_gateway.this : k => v.id }
}

output "nat_gateway_public_ips" {
  description = "Public IPv4 addresses of the NAT gateways. These are the source addresses an external service sees for traffic originating in private subnets."
  value       = { for k, v in aws_nat_gateway.this : k => v.public_ip }
}

output "nat_gateway_count" {
  description = "How many NAT gateways were created. Multiply by roughly USD 43 per month, then add data processing charges, to estimate the standing cost."
  value       = length(aws_nat_gateway.this)
}
