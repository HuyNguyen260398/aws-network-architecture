# =============================================================================
# Network ACL on the data tier.
#
# The security groups already restrict the database to the app tier. This is
# the second control, and a different kind: it belongs to the SUBNET rather
# than the instance, and it is STATELESS.
#
# Stateless means replies are not allowed back automatically. Every flow needs
# a rule in each direction, and the reply direction is to an ephemeral port.
# =============================================================================

resource "aws_network_acl" "data" {
  vpc_id     = module.vpc.vpc_id
  subnet_ids = [for key in keys(local.data_subnets) : module.vpc.private_subnet_ids[key]]

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-nacl-data" })
}

# Inbound: the database port, from each app subnet. One rule per subnet,
# because a network ACL can name address ranges but not security groups.
resource "aws_network_acl_rule" "data_in_database" {
  for_each = { for i, key in sort(keys(local.app_subnets)) : key => { index = i, cidr = local.app_subnets[key].cidr_block } }

  network_acl_id = aws_network_acl.data.id
  rule_number    = 100 + each.value.index
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = each.value.cidr
  from_port      = local.database_port
  to_port        = local.database_port
}

resource "aws_network_acl_rule" "data_in_icmp" {
  network_acl_id = aws_network_acl.data.id
  rule_number    = 120
  egress         = false
  protocol       = "icmp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  icmp_type      = -1
  icmp_code      = -1
}

# Inbound replies to connections the database host itself opens (operating
# system updates, Systems Manager). Unused until lab 03 gives it a way out,
# but without this rule that way out would not work.
resource "aws_network_acl_rule" "data_in_ephemeral" {
  network_acl_id = aws_network_acl.data.id
  rule_number    = 130
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

# Outbound: replies to the app tier. The app host connected FROM an ephemeral
# port, so that is where the reply goes. Delete this rule and the database
# receives every request and answers none of them.
resource "aws_network_acl_rule" "data_out_ephemeral" {
  network_acl_id = aws_network_acl.data.id
  rule_number    = 100
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "data_out_https" {
  network_acl_id = aws_network_acl.data.id
  rule_number    = 110
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 443
  to_port        = 443
}

resource "aws_network_acl_rule" "data_out_icmp" {
  network_acl_id = aws_network_acl.data.id
  rule_number    = 120
  egress         = true
  protocol       = "icmp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  icmp_type      = -1
  icmp_code      = -1
}

output "data_network_acl_id" {
  description = "Network ACL attached to the data subnets."
  value       = aws_network_acl.data.id
}

output "verify_nacl" {
  description = "Read-only AWS CLI command listing the data-tier network ACL rules in evaluation order."
  value       = "aws ec2 describe-network-acls --network-acl-ids ${aws_network_acl.data.id} --region ${var.aws_region} --query 'sort_by(NetworkAcls[0].Entries,&RuleNumber)[].{Num:RuleNumber,Egress:Egress,Proto:Protocol,Action:RuleAction,CIDR:CidrBlock,Ports:PortRange}' --output table"
}
