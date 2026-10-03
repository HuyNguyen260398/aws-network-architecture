# =============================================================================
# The servers.
#
# Lab 01: one server ran everything.
# Lab 02: one server per tier, each in its own subnet:
#
#   web  (public-a)  frontend  :80    reachable from the internet
#   app  (app-a)     payment   :9090  reachable from the web tier only
#   db   (data-a)    database  :3306  reachable from the app tier only
#
# Lab 05: with the load balancer enabled, the web server stops accepting
#         connections from the internet directly.
#
# A request to the frontend calls payment, which calls the database, so one
# curl to the web server proves -- or disproves -- every hop.
# =============================================================================

variable "allowed_client_cidr" {
  description = "IPv4 range allowed to reach the shop from the internet. 0.0.0.0/0 means anyone; use your own address as a /32 to keep the lab private."
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrhost(var.allowed_client_cidr, 0))
    error_message = "allowed_client_cidr must be a valid IPv4 CIDR, for example 203.0.113.7/32."
  }
}

variable "enable_host_firewall" {
  description = "Install nftables on the internet-facing host and drop inbound traffic to any port the shop does not serve. This is the host firewall: a second layer behind the security group."
  type        = bool
  default     = true
}

locals {
  frontend_port = 80
  payment_port  = 9090
  # The port MySQL listens on. The stand-in is not a database; it only proves
  # that TCP 3306 is reachable from where it should be and nowhere else.
  database_port = 3306

  icmp_from_vpc = {
    description = "ICMP echo request from inside the VPC, for ping tests"
    ip_protocol = "icmp"
    from_port   = 8
    to_port     = -1
    cidr_ipv4   = var.vpc_cidr
  }
}

# The lab 01 server becomes the web tier. Telling Terraform it MOVED keeps its
# security group and IAM role instead of destroying and recreating them.
moved {
  from = module.server
  to   = module.web
}

moved {
  from = module.server_apps
  to   = module.web_apps
}

# -----------------------------------------------------------------------------
# Data tier
# -----------------------------------------------------------------------------
module "db_apps" {
  source = "../../modules/demo-service"

  services = {
    database = { port = local.database_port }
  }
}

module "db" {
  source = "../../modules/test-instance"

  name          = "${local.name_prefix}-db"
  vpc_id        = module.vpc.vpc_id
  subnet_id     = module.vpc.private_subnet_ids["data-a"]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  user_data                   = module.db_apps.user_data
  user_data_replace_on_change = true

  ingress_rules = {
    # The source is a SECURITY GROUP, not an address range. Any instance in the
    # app tier's group may connect, whatever its IP is now or becomes later.
    database_from_app = {
      description                  = "Database port from the app tier only"
      ip_protocol                  = "tcp"
      from_port                    = local.database_port
      to_port                      = local.database_port
      referenced_security_group_id = module.app.security_group_id
    }
    icmp = local.icmp_from_vpc
  }

  tags = merge(local.common_tags, { Tier = "data" })
}

# -----------------------------------------------------------------------------
# App tier
# -----------------------------------------------------------------------------
module "app_apps" {
  source = "../../modules/demo-service"

  services = {
    payment = { port = local.payment_port, upstream_url = "http://${module.db.private_ip}:${local.database_port}/" }
  }
}

module "app" {
  source = "../../modules/test-instance"

  name          = "${local.name_prefix}-app"
  vpc_id        = module.vpc.vpc_id
  subnet_id     = module.vpc.private_subnet_ids["app-a"]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  user_data                   = module.app_apps.user_data
  user_data_replace_on_change = true

  ingress_rules = {
    payment_from_web = {
      description                  = "Payment service from the web tier only"
      ip_protocol                  = "tcp"
      from_port                    = local.payment_port
      to_port                      = local.payment_port
      referenced_security_group_id = module.web.security_group_id
    }
    icmp = local.icmp_from_vpc
  }

  tags = merge(local.common_tags, { Tier = "app" })
}

# -----------------------------------------------------------------------------
# Web tier
# -----------------------------------------------------------------------------
module "web_apps" {
  source = "../../modules/demo-service"

  services = {
    frontend = { port = local.frontend_port, upstream_url = "http://${module.app.private_ip}:${local.payment_port}/" }
  }

  # Only the web host can install nftables: it is the only one with a path to
  # the package repositories. Lab 03 gives the private tiers that path.
  host_firewall_allowed_tcp_ports = var.enable_host_firewall ? [local.frontend_port] : null
}

module "web" {
  source = "../../modules/test-instance"

  name          = "${local.name_prefix}-web"
  vpc_id        = module.vpc.vpc_id
  subnet_id     = module.vpc.public_subnet_ids["public-a"]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  associate_public_ip_address = true

  user_data                   = module.web_apps.user_data
  user_data_replace_on_change = true

  # With a load balancer in front, clients no longer connect to this host, so
  # the rule that let the whole internet in is withdrawn. load-balancing.tf
  # adds the replacement: port 80 from the load balancer's security group.
  ingress_rules = merge(
    local.load_balancer_enabled ? {} : {
      frontend = {
        description = "Shop frontend from the internet"
        ip_protocol = "tcp"
        from_port   = local.frontend_port
        to_port     = local.frontend_port
        cidr_ipv4   = var.allowed_client_cidr
      }
    },
    { icmp = local.icmp_from_vpc },
  )

  tags = merge(local.common_tags, { Tier = "web" })
}

output "instance_ids" {
  description = "Instance ID of the host in each tier."
  value = {
    web = module.web.instance_id
    app = module.app.instance_id
    db  = module.db.instance_id
  }
}

output "private_ips" {
  description = "Private IPv4 address of the host in each tier."
  value = {
    web = module.web.private_ip
    app = module.app.private_ip
    db  = module.db.private_ip
  }
}

output "security_group_ids" {
  description = "Security group of each tier. The app group is the SOURCE in the database rule, and the web group is the source in the payment rule."
  value = {
    web = module.web.security_group_id
    app = module.app.security_group_id
    db  = module.db.security_group_id
  }
}

output "web_public_ip" {
  description = "Public IPv4 address of the web server -- the only host in the project that has one."
  value       = module.web.public_ip
}

output "ssm_web" {
  description = "Open a shell on the web server with Session Manager. It is the only host with a path to Systems Manager until lab 03 or 04."
  value       = module.web.ssm_start_session_command
}

output "verify_compute" {
  description = "Commands for checking the tiers. Run the first two from your own machine and the last three from a shell on the web server."
  value = {
    whole_chain_from_internet  = "curl -s ${local.load_balancer_enabled ? "http://${aws_lb.shop[0].dns_name}/" : "http://${module.web.public_ip}/"}"
    payment_closed_to_internet = "curl -s --max-time 5 http://${module.web.public_ip}:${local.payment_port}/ || echo 'timed out, as intended'"

    from_web_payment_allowed  = "curl -s http://${module.app.private_ip}:${local.payment_port}/"
    from_web_database_blocked = "curl -s --max-time 5 http://${module.db.private_ip}:${local.database_port}/ || echo 'timed out, as intended'"
    from_web_listening_ports  = "sudo ss -ltnp"

    security_group_rules = "aws ec2 describe-security-group-rules --filters Name=group-id,Values=${module.web.security_group_id},${module.app.security_group_id},${module.db.security_group_id} --region ${var.aws_region} --query 'SecurityGroupRules[?!IsEgress].{Group:GroupId,Proto:IpProtocol,Port:FromPort,Cidr:CidrIpv4,SourceGroup:ReferencedGroupInfo.GroupId}' --output table"
  }
}
