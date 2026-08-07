locals {
  lab_name    = "10-troubleshooting-challenges"
  name_prefix = "${var.project_name}-lab10"

  common_tags = merge(
    {
      Project     = var.project_name
      Lab         = local.lab_name
      Environment = "learning"
      ManagedBy   = "terraform"
      Lifecycle   = "ephemeral"
      # Deliberately misconfigured infrastructure. The tag is here so that
      # anyone who finds these resources later knows they are broken on purpose.
      Warning = "intentionally-misconfigured"
    },
    var.additional_tags,
  )

  # One boolean per challenge, so main.tf reads as a list of scenarios rather
  # than a thicket of contains() calls.
  c = {
    missing_route       = contains(var.challenges, "missing-route")
    overlapping_cidr    = contains(var.challenges, "overlapping-cidr")
    security_group      = contains(var.challenges, "security-group")
    nacl_ephemeral      = contains(var.challenges, "nacl-ephemeral")
    broken_dns          = contains(var.challenges, "broken-dns")
    endpoint_policy     = contains(var.challenges, "endpoint-policy")
    missing_association = contains(var.challenges, "missing-association")
    asymmetric_routing  = contains(var.challenges, "asymmetric-routing")
    flow_log_rejects    = contains(var.challenges, "flow-log-rejects")
  }

  # A peer VPC is needed by the routing challenges.
  need_peer_vpc = local.c.missing_route || local.c.asymmetric_routing

  # The overlapping-cidr challenge needs a second VPC using the SAME range as
  # the base VPC. Two VPCs with identical CIDRs is perfectly legal -- it is
  # only peering them that is impossible, which is the point.
  need_overlap_vpc = local.c.overlapping_cidr

  need_s3_endpoint = local.c.endpoint_policy || local.c.missing_association

  need_flow_logs = local.c.flow_log_rejects

  service_port = 8080

  base_public_subnets = {
    "public-a" = {
      cidr_block              = cidrsubnet(var.base_vpc_cidr, var.subnet_newbits, 0)
      az_index                = 0
      map_public_ip_on_launch = true
    }
  }

  base_private_subnets = merge(
    {
      "app-a" = {
        cidr_block = cidrsubnet(var.base_vpc_cidr, var.subnet_newbits, 10)
        az_index   = 0
      }
    },
    # A second private subnet, in a second Availability Zone, used by the
    # asymmetric-routing challenge. It gets its own route table -- which is
    # exactly how asymmetric routing happens in the wild.
    local.c.asymmetric_routing ? {
      "app-b" = {
        cidr_block = cidrsubnet(var.base_vpc_cidr, var.subnet_newbits, 11)
        az_index   = 1
      }
    } : {},
  )

  peer_subnets = {
    "public-a" = {
      cidr_block              = cidrsubnet(var.peer_vpc_cidr, var.subnet_newbits, 0)
      az_index                = 0
      map_public_ip_on_launch = true
    }
  }

  server_user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    mkdir -p /opt/service
    echo "lab10 target reached" > /opt/service/index.html
    cat > /etc/systemd/system/labservice.service <<'UNIT'
    [Unit]
    Description=Lab 10 troubleshooting target
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

  estimated_hourly_usd = var.enable_test_instances ? (
    2 * 0.0053 + 0.005 + (local.need_peer_vpc ? 0.0053 + 0.005 : 0)
  ) : 0

  # One line per enabled challenge, surfaced as an output so a learner knows
  # what they are looking for without opening HINTS.md.
  briefs = {
    missing-route       = "From the client, ping the peer VPC's instance. It fails. The peering connection is 'active'. Find out why no packet gets through."
    overlapping-cidr    = "Two VPCs have been created. Your task: peer them. Work out why you cannot, and what the options are."
    security-group      = "From the client, curl the server on port ${local.service_port}. It times out. The network ACLs allow everything. Find the rule that is wrong."
    nacl-ephemeral      = "From the server, make an outbound connection. It hangs. Outbound is allowed by every rule you can find. Explain what is dropping the reply."
    broken-dns          = "A private hosted zone exists with a record in it. Resolving that record from the client returns NXDOMAIN. The record is correct. Find out why."
    endpoint-policy     = "From the server, read an object from the lab bucket over the S3 gateway endpoint. It is denied. The instance role allows S3 reads. Find the other policy."
    missing-association = "An S3 gateway endpoint exists and is 'available'. S3 access from the private subnet still times out. Explain what an endpoint actually does."
    asymmetric-routing  = "Two private subnets, apparently identical. One can reach the peer VPC and one cannot. Find the difference."
    flow-log-rejects    = "Traffic between two hosts is being dropped. Flow logs are enabled. Use them to determine WHICH layer is dropping it, then fix it."
  }

  active_briefs = { for k, v in local.briefs : k => v if contains(var.challenges, k) }
}
