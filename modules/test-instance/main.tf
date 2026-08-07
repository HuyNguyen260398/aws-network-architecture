# =============================================================================
# Disposable test instance
#
# A minimal EC2 host used to prove that networking works: ping a peer, curl an
# endpoint, dig a private hosted zone record, watch a flow log entry appear.
#
# Access is through AWS Systems Manager Session Manager only. There is no key
# pair, no SSH ingress rule, and no bastion. That is not just a security
# posture -- it is also what lets the same module work in a private subnet with
# no internet route at all, provided the SSM interface endpoints exist.
# =============================================================================

data "aws_region" "current" {}

data "aws_ami" "this" {
  count = var.ami_id == null ? 1 : 0

  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = [local.ami_name_filter]
  }

  filter {
    name   = "architecture"
    values = [var.architecture]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# -----------------------------------------------------------------------------
# Instance profile for Session Manager
#
# AmazonSSMManagedInstanceCore is the minimum for Session Manager. It grants the
# agent permission to register the instance, poll for commands, and open a
# session channel -- and nothing else. Do not swap it for a broader policy.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "this" {
  count = local.create_role ? 1 : 0

  name_prefix = substr("${var.name}-", 0, 32)
  description = "Session Manager access for the ${var.name} networking lab instance"

  # Written inline rather than via aws_iam_policy_document: a trust policy this
  # small is easier to read as JSON, and it keeps the module free of a data
  # source that exists only to render four lines.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  count = local.create_role && var.enable_ssm ? 1 : 0

  role       = aws_iam_role.this[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "additional" {
  for_each = local.create_role ? var.additional_iam_policy_arns : {}

  role       = aws_iam_role.this[0].name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "this" {
  count = local.create_role ? 1 : 0

  name_prefix = substr("${var.name}-", 0, 32)
  role        = aws_iam_role.this[0].name

  tags = local.tags
}

# -----------------------------------------------------------------------------
# Security group
#
# No ingress rules by default. An instance managed through Session Manager needs
# none: the SSM agent dials OUT to the Systems Manager endpoints, and the
# session is carried back over that connection. Security groups are stateful, so
# the return traffic is allowed automatically.
# -----------------------------------------------------------------------------
resource "aws_security_group" "this" {
  count = var.create_security_group ? 1 : 0

  name_prefix = "${var.name}-"
  description = "Networking lab instance ${var.name}. Session Manager access only; no inbound rules by default."
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${var.name}-sg" })

  lifecycle {
    # The instance references this group, so the replacement must exist before
    # the old one is removed.
    create_before_destroy = true
  }
}

# Rules live in separate resources rather than inline blocks. Inline rules are
# authoritative for the whole group, so a rule added by hand in the console gets
# silently deleted on the next apply -- confusing during a troubleshooting lab.
resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = var.create_security_group ? var.ingress_rules : {}

  security_group_id = aws_security_group.this[0].id
  description       = each.value.description
  ip_protocol       = each.value.ip_protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port

  cidr_ipv4                    = each.value.cidr_ipv4
  cidr_ipv6                    = each.value.cidr_ipv6
  referenced_security_group_id = each.value.referenced_security_group_id
  prefix_list_id               = each.value.prefix_list_id

  tags = merge(local.tags, { Name = "${var.name}-ingress-${each.key}" })
}

resource "aws_vpc_security_group_egress_rule" "this" {
  for_each = var.create_security_group ? var.egress_rules : {}

  security_group_id = aws_security_group.this[0].id
  description       = each.value.description
  ip_protocol       = each.value.ip_protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port

  cidr_ipv4                    = each.value.cidr_ipv4
  cidr_ipv6                    = each.value.cidr_ipv6
  referenced_security_group_id = each.value.referenced_security_group_id
  prefix_list_id               = each.value.prefix_list_id

  tags = merge(local.tags, { Name = "${var.name}-egress-${each.key}" })
}

# -----------------------------------------------------------------------------
# The instance
# -----------------------------------------------------------------------------
resource "aws_instance" "this" {
  ami           = local.ami_id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id

  vpc_security_group_ids = local.security_group_ids
  iam_instance_profile   = local.create_role ? aws_iam_instance_profile.this[0].name : null

  associate_public_ip_address = var.associate_public_ip_address
  source_dest_check           = var.source_dest_check
  monitoring                  = var.enable_detailed_monitoring

  user_data                   = var.user_data
  user_data_replace_on_change = var.user_data_replace_on_change

  # IMDSv2 only. IMDSv1's unauthenticated GET is what turns a server-side
  # request forgery bug into stolen instance credentials; requiring a session
  # token closes it. hop_limit 1 stops a container on the instance from
  # reaching the metadata service through the host.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true

    tags = merge(local.tags, { Name = "${var.name}-root" })
  }

  tags = merge(local.tags, { Name = var.name })

  lifecycle {
    precondition {
      condition     = var.architecture == "arm64" ? local.is_graviton_type : !local.is_graviton_type
      error_message = "instance_type '${var.instance_type}' and architecture '${var.architecture}' do not match. Graviton families (t4g, m7g, c7g, r7g and friends) need arm64; every other family needs x86_64."
    }

    precondition {
      condition     = local.ami_id != null
      error_message = "No AMI matched '${local.ami_name_filter}' for architecture ${var.architecture} in ${data.aws_region.current.region}. Pass ami_id explicitly, or adjust ami_name_filter."
    }

    precondition {
      condition     = length(local.security_group_ids) > 0
      error_message = "The instance has no security group. Either leave create_security_group true or pass at least one entry in security_group_ids -- otherwise AWS attaches the VPC default group, which modules/vpc deliberately strips of all rules."
    }
  }
}
