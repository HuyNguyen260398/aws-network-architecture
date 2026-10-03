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
}

run "defaults" {
  command = plan

  # Advisory checks that fire on purpose with the default, zero-cost settings.
  expect_failures = [
    check.private_hosts_reachable_via_session_manager,
  ]
}

run "every_opt_in_enabled" {
  command = plan

  variables {
    public_zone_name           = "example.com"
    acknowledge_costs          = true
    enable_nat_gateway         = true
    nat_gateway_mode           = "per_az"
    enable_ipv6                = true
    enable_interface_endpoints = true
    enable_load_balancer       = true
  }
}
