# =============================================================================
# The servers.
#
# Lab 01: ONE server, in the public subnet, running BOTH shop applications.
# The frontend listens on TCP 80 and the payment service on TCP 9090. One IP
# address, two applications, told apart only by port number.
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
}

module "server_apps" {
  source = "../../modules/demo-service"

  services = {
    # The frontend calls the payment service over loopback. Same host, so the
    # only thing separating the two applications is the port number.
    frontend = { port = local.frontend_port, upstream_url = "http://127.0.0.1:${local.payment_port}/" }
    payment  = { port = local.payment_port }
  }

  host_firewall_allowed_tcp_ports = var.enable_host_firewall ? [local.frontend_port, local.payment_port] : null
}

module "server" {
  source = "../../modules/test-instance"

  name          = "${local.name_prefix}-server"
  vpc_id        = module.vpc.vpc_id
  subnet_id     = module.vpc.public_subnet_ids["public-a"]
  instance_type = var.instance_type
  architecture  = var.instance_architecture

  associate_public_ip_address = true

  user_data                   = module.server_apps.user_data
  user_data_replace_on_change = true

  # The security group is a firewall at the network interface. It filters on
  # exactly the two things the video describes: source address and
  # destination port.
  ingress_rules = {
    frontend = {
      description = "Shop frontend from the internet"
      ip_protocol = "tcp"
      from_port   = local.frontend_port
      to_port     = local.frontend_port
      cidr_ipv4   = var.allowed_client_cidr
    }
    # Exposing the payment service to the internet is a mistake that lab 02
    # corrects. It is open here so you can see two ports on one address.
    payment = {
      description = "Payment service from the internet -- closed in lab 02"
      ip_protocol = "tcp"
      from_port   = local.payment_port
      to_port     = local.payment_port
      cidr_ipv4   = var.allowed_client_cidr
    }
  }

  tags = merge(local.common_tags, { Tier = "all-in-one" })
}

output "server_instance_id" {
  description = "Instance ID of the single shop server."
  value       = module.server.instance_id
}

output "server_public_ip" {
  description = "Public IPv4 address of the shop server. This is the address the internet sends packets to."
  value       = module.server.public_ip
}

output "server_private_ip" {
  description = "Private IPv4 address of the shop server. This is the only address the server itself knows about; the internet gateway translates between the two."
  value       = module.server.private_ip
}

output "frontend_url" {
  description = "The shop frontend: public IP, port 80."
  value       = "http://${module.server.public_ip}/"
}

output "payment_url" {
  description = "The payment service: SAME public IP, port 9090."
  value       = "http://${module.server.public_ip}:${local.payment_port}/"
}

output "ssm_server" {
  description = "Open a shell on the shop server with Session Manager."
  value       = module.server.ssm_start_session_command
}

output "verify_compute" {
  description = "Commands for checking the server. Run the first two from your own machine."
  value = {
    frontend_port_80  = "curl -s http://${module.server.public_ip}/"
    payment_port_9090 = "curl -s http://${module.server.public_ip}:${local.payment_port}/"

    aws_assigned_dns_name = "aws ec2 describe-instances --instance-ids ${module.server.instance_id} --region ${var.aws_region} --query 'Reservations[0].Instances[0].{PublicDns:PublicDnsName,PublicIp:PublicIpAddress,PrivateIp:PrivateIpAddress}' --output table"

    security_group_rules = "aws ec2 describe-security-group-rules --filters Name=group-id,Values=${module.server.security_group_id} --region ${var.aws_region} --query 'SecurityGroupRules[].{Egress:IsEgress,Proto:IpProtocol,From:FromPort,To:ToPort,Cidr:CidrIpv4}' --output table"
  }
}
