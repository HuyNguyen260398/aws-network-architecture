locals {
  lab_name    = "08-security-and-observability"
  name_prefix = "${var.project_name}-lab08"

  common_tags = merge(
    {
      Project     = var.project_name
      Lab         = local.lab_name
      Environment = "learning"
      ManagedBy   = "terraform"
      Lifecycle   = "ephemeral"
    },
    var.additional_tags,
  )

  create_firewall = var.enable_network_firewall && var.acknowledge_costs

  public_subnets = {
    "public-a" = {
      cidr_block              = cidrsubnet(var.vpc_cidr, var.subnet_newbits, 0)
      az_index                = 0
      map_public_ip_on_launch = true
    }
  }

  private_subnets = merge(
    {
      "private-a" = {
        cidr_block = cidrsubnet(var.vpc_cidr, var.subnet_newbits, 10)
        az_index   = 0
      }
    },
    # A dedicated subnet for the firewall endpoint. AWS requires the firewall to
    # live in a subnet of its own -- sharing one with workloads creates a
    # routing loop, because the firewall subnet's route table must NOT send
    # traffic back through the firewall.
    local.create_firewall ? {
      "firewall-a" = {
        cidr_block = cidrsubnet(var.vpc_cidr, var.subnet_newbits, 20)
        az_index   = 0
      }
    } : {},
  )

  service_port = 8080

  # A tiny HTTP service on the private host, so there is something real to
  # connect to and something real to block.
  server_user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    mkdir -p /opt/service
    echo "lab08 server reached successfully" > /opt/service/index.html
    cat > /etc/systemd/system/labservice.service <<'UNIT'
    [Unit]
    Description=Lab 08 observability target
    After=network-online.target

    [Service]
    WorkingDirectory=/opt/service
    ExecStart=/usr/bin/python3 -m http.server ${local.service_port} --bind 0.0.0.0
    Restart=always

    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now labservice.service
  EOT

  # The firewall endpoint ID has to be dug out of the firewall's status. There
  # is one sync state per Availability Zone the firewall is deployed into; this
  # lab uses one zone.
  firewall_endpoint_id = local.create_firewall ? one([
    for state in tolist(aws_networkfirewall_firewall.this[0].firewall_status[0].sync_states) :
    state.attachment[0].endpoint_id
  ]) : null

  estimated_hourly_usd = (
    (local.create_firewall ? 0.395 : 0)
    + (var.enable_test_instances ? 2 * 0.0053 + 0.005 : 0)
  )
}
