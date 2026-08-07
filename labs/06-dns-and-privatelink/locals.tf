locals {
  lab_name    = "06-dns-and-privatelink"
  name_prefix = "${var.project_name}-lab06"

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

  create_privatelink       = var.enable_privatelink && var.acknowledge_costs
  create_resolver_inbound  = var.enable_resolver_inbound_endpoint && var.acknowledge_costs
  create_resolver_outbound = var.enable_resolver_outbound_endpoint && var.acknowledge_costs
  create_provider_instance = local.create_privatelink && var.enable_test_instances

  # Both VPCs get two subnets in two Availability Zones. Two zones is not
  # optional here: a Network Load Balancer needs at least one subnet and
  # Resolver endpoints REQUIRE two ENIs in different zones.
  vpcs = {
    provider = var.provider_vpc_cidr
    consumer = var.consumer_vpc_cidr
  }

  subnets = {
    for name, cidr in local.vpcs : name => {
      "public-a" = {
        cidr_block              = cidrsubnet(cidr, var.subnet_newbits, 0)
        az_index                = 0
        map_public_ip_on_launch = true
      }
      "public-b" = {
        cidr_block              = cidrsubnet(cidr, var.subnet_newbits, 1)
        az_index                = 1
        map_public_ip_on_launch = true
      }
    }
  }

  # A tiny HTTP service, so the PrivateLink test returns something recognisable
  # rather than a connection that merely does not fail. Python 3 ships with
  # Amazon Linux 2023.
  provider_user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    mkdir -p /opt/service
    cat > /opt/service/index.html <<'HTML'
    Hello from the PROVIDER VPC, reached over AWS PrivateLink.
    Your packets never left the AWS network and no routes were exchanged.
    HTML
    cat > /etc/systemd/system/labservice.service <<'UNIT'
    [Unit]
    Description=Lab 06 provider service
    After=network-online.target

    [Service]
    WorkingDirectory=/opt/service
    ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
    Restart=always

    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now labservice.service
  EOT

  # Rough standing cost. Resolver endpoints dominate everything else.
  estimated_hourly_usd = (
    (local.create_privatelink ? 0.0225 + 0.006 + 0.011 : 0)
    + (local.create_resolver_inbound ? 0.25 : 0)
    + (local.create_resolver_outbound ? 0.25 : 0)
    + (var.enable_test_instances ? 0.0053 + 0.005 : 0)
    + (local.create_provider_instance ? 0.0053 + 0.005 : 0)
  )
}
