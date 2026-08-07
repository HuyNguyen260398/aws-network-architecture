output "instance_id" {
  description = "EC2 instance ID. Use it with 'aws ssm start-session --target <id>'."
  value       = aws_instance.this.id
}

output "instance_arn" {
  description = "ARN of the instance."
  value       = aws_instance.this.arn
}

output "private_ip" {
  description = "Primary private IPv4 address. This is the address other instances in the VPC use to reach it, and the one that appears in VPC Flow Logs."
  value       = aws_instance.this.private_ip
}

output "public_ip" {
  description = "Public IPv4 address, or empty when associate_public_ip_address is false. An instance with no public IP is not reachable from the internet regardless of its security group."
  value       = aws_instance.this.public_ip
}

output "ipv6_addresses" {
  description = "IPv6 addresses assigned to the instance. Every IPv6 address on AWS is globally routable; reachability is controlled by routing and security groups, not by address scope."
  value       = aws_instance.this.ipv6_addresses
}

output "private_dns" {
  description = "Private DNS name assigned by the VPC's Amazon-provided resolver."
  value       = aws_instance.this.private_dns
}

output "availability_zone" {
  description = "Availability Zone the instance landed in. Traffic between AZs is billed in both directions, which matters when a single NAT gateway serves several zones."
  value       = aws_instance.this.availability_zone
}

output "primary_network_interface_id" {
  description = "ID of the primary ENI. This is the resource you target for VPC Flow Logs at interface scope, for traffic mirroring, and as an endpoint in Reachability Analyzer."
  value       = aws_instance.this.primary_network_interface_id
}

output "security_group_id" {
  description = "ID of the security group created by this module, or null when create_security_group is false."
  value       = one(aws_security_group.this[*].id)
}

output "security_group_ids" {
  description = "Every security group attached to the instance."
  value       = local.security_group_ids
}

output "iam_role_arn" {
  description = "ARN of the instance role, or null when no role was created."
  value       = one(aws_iam_role.this[*].arn)
}

output "ami_id" {
  description = "AMI the instance was launched from."
  value       = local.ami_id
}

output "ssm_start_session_command" {
  description = "Ready-to-run command that opens a shell on this instance. It works only once the SSM agent has registered, which takes a minute or two after launch and requires a network path to the Systems Manager endpoints."
  value       = "aws ssm start-session --target ${aws_instance.this.id} --region ${data.aws_region.current.region}"
}
