# Plans this lab against a mocked AWS provider: no credentials, no API calls,
# nothing created. It catches what `terraform validate` cannot -- dependency
# cycles, for_each keys that are unknown at plan time, failing variable
# validations -- for the default settings and with every opt-in switched on.
#
#   terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }

  mock_data "aws_ami" {
    defaults = {
      id           = "ami-0123456789abcdef0"
      architecture = "arm64"
    }
  }

  mock_resource "aws_vpc" {
    defaults = {
      ipv6_cidr_block = "2001:db8:1234::/56"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/mock"
    }
  }

  mock_data "aws_vpc_endpoint_service" {
    defaults = {
      service_name = "com.amazonaws.ap-southeast-1.mocked"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }
}

mock_provider "aws" {
  alias = "dr"

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }

  mock_data "aws_ami" {
    defaults = {
      id           = "ami-0123456789abcdef0"
      architecture = "arm64"
    }
  }

  mock_resource "aws_vpc" {
    defaults = {
      ipv6_cidr_block = "2001:db8:1234::/56"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/mock"
    }
  }

  mock_data "aws_vpc_endpoint_service" {
    defaults = {
      service_name = "com.amazonaws.ap-southeast-1.mocked"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }
}

run "defaults" {
  command = plan

  # Advisory checks that fire on purpose with the default, zero-cost settings.
  expect_failures = [
    check.private_hosts_reachable_via_session_manager,
    check.transit_gateway_is_disabled,
    check.vpn_is_disabled,
  ]
}

run "every_opt_in_enabled" {
  command = plan

  variables {
    public_zone_name                  = "example.com"
    acknowledge_costs                 = true
    enable_nat_gateway                = true
    nat_gateway_mode                  = "per_az"
    enable_ipv6                       = true
    enable_interface_endpoints        = true
    enable_load_balancer              = true
    enable_ecs                        = true
    enable_eks                        = true
    enable_nacl_block                 = true
    run_reachability_analysis         = true
    enable_cloudtrail                 = true
    enable_network_firewall           = true
    enable_transit_gateway            = true
    allow_dev_to_shop                 = true
    split_horizon_domain              = "example.com"
    enable_privatelink                = true
    enable_resolver_inbound_endpoint  = true
    enable_resolver_outbound_endpoint = true
    enable_site_to_site_vpn           = true
    enable_direct_connect_gateway     = true
    enable_transit_gateway_peering    = true
    enable_dns_failover               = true
  }

  # Cost warnings that fire on purpose when an expensive opt-in is on.
  expect_failures = [
    check.firewall_is_disabled,
  ]
}

run "each_challenge_plans" {
  command = plan

  variables {
    acknowledge_costs    = true
    enable_load_balancer = true
    challenges           = ["missing-route", "security-group", "nacl-ephemeral", "wrong-next-hop", "broken-dns", "listener-rule-order"]
  }

  expect_failures = [
    check.one_challenge_at_a_time,
    check.private_hosts_reachable_via_session_manager,
    check.transit_gateway_is_disabled,
    check.vpn_is_disabled,
  ]
}
