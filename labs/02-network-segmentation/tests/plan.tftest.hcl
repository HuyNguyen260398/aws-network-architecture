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
}

run "defaults" {
  command = plan
}

run "every_opt_in_enabled" {
  command = plan

  variables {
    public_zone_name = "example.com"
  }
}
