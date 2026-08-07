# Tests for modules/vpc.
#
# Every run uses `command = plan` against a mocked AWS provider: no credentials
# are needed, no API calls are made, and nothing is created. Assertions are
# restricted to values that are knowable at plan time -- CIDRs, tags, counts and
# routing shape -- because computed attributes such as subnet IDs are unknown
# until apply.
#
#   terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
    }
  }

  mock_resource "aws_vpc" {
    defaults = {
      # A real, parseable /56 so that cidrsubnet() in locals.tf has something
      # valid to work with when IPv6 is exercised.
      ipv6_cidr_block = "2001:db8:1234::/56"
    }
  }
}

variables {
  name               = "test"
  cidr_block         = "10.0.0.0/16"
  availability_zones = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
}

# -----------------------------------------------------------------------------
# An empty VPC is still a valid VPC.
# -----------------------------------------------------------------------------
run "vpc_only_defaults" {
  command = plan

  assert {
    condition     = aws_vpc.this.cidr_block == "10.0.0.0/16"
    error_message = "VPC should use the supplied CIDR block."
  }

  assert {
    condition     = aws_vpc.this.enable_dns_support && aws_vpc.this.enable_dns_hostnames
    error_message = "DNS support and hostnames must default to on, or interface endpoint private DNS and Route 53 private hosted zones will not resolve."
  }

  assert {
    condition     = aws_vpc.this.assign_generated_ipv6_cidr_block == false
    error_message = "IPv6 must be opt-in."
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 0
    error_message = "No NAT gateway may be created by default -- it is the most common source of surprise charges."
  }

  assert {
    condition     = length(aws_eip.nat) == 0
    error_message = "No Elastic IP may be allocated by default."
  }

  assert {
    condition     = length(aws_default_security_group.this) == 1
    error_message = "The default security group must be managed so that its permissive default rules are stripped."
  }

  assert {
    condition     = length(aws_route_table.public) == 0
    error_message = "With no public subnets there is nothing for a public route table to serve."
  }
}

# -----------------------------------------------------------------------------
# The core lesson: routing, not naming, makes a subnet public.
# -----------------------------------------------------------------------------
run "public_and_private_subnets" {
  command = plan

  variables {
    public_subnets = {
      "public-a" = { cidr_block = "10.0.0.0/24", az_index = 0, map_public_ip_on_launch = true }
      "public-b" = { cidr_block = "10.0.1.0/24", az_index = 1 }
    }
    private_subnets = {
      "app-a" = { cidr_block = "10.0.10.0/24", az_index = 0 }
      "app-b" = { cidr_block = "10.0.11.0/24", az_index = 1 }
    }
  }

  assert {
    condition     = aws_subnet.public["public-a"].cidr_block == "10.0.0.0/24"
    error_message = "Public subnet CIDR should come straight from the input map."
  }

  assert {
    condition     = aws_subnet.public["public-a"].availability_zone == "ap-southeast-1a"
    error_message = "az_index 0 must resolve to the first Availability Zone in the list."
  }

  assert {
    condition     = aws_subnet.private["app-b"].availability_zone == "ap-southeast-1b"
    error_message = "az_index 1 must resolve to the second Availability Zone."
  }

  assert {
    condition     = aws_subnet.public["public-a"].map_public_ip_on_launch == true
    error_message = "map_public_ip_on_launch must be honoured per subnet."
  }

  assert {
    condition     = aws_subnet.public["public-b"].map_public_ip_on_launch == false
    error_message = "map_public_ip_on_launch must default to false, because public IPv4 addresses are billed hourly."
  }

  assert {
    condition     = length(aws_route_table.public) == 1
    error_message = "Public subnets share a single route table."
  }

  assert {
    condition     = length(aws_route.public_default_ipv4) == 1 && aws_route.public_default_ipv4[0].destination_cidr_block == "0.0.0.0/0"
    error_message = "The public route table needs a 0.0.0.0/0 route to the internet gateway. This route is the only thing that makes the subnet public."
  }

  assert {
    condition     = length(aws_route_table.private) == 2
    error_message = "One private route table per Availability Zone in use."
  }

  assert {
    condition     = length(aws_route.private_default_ipv4) == 0
    error_message = "With nat_gateway_mode = none the private route tables must have no default route, leaving those subnets genuinely isolated."
  }

  assert {
    condition     = length(aws_route_table_association.private) == 2
    error_message = "Every private subnet must be explicitly associated with a route table, so none of them falls back to the main table."
  }
}

# -----------------------------------------------------------------------------
# NAT modes
# -----------------------------------------------------------------------------
run "nat_single_creates_exactly_one_gateway" {
  command = plan

  variables {
    nat_gateway_mode = "single"
    public_subnets = {
      "public-a" = { cidr_block = "10.0.0.0/24", az_index = 0 }
      "public-b" = { cidr_block = "10.0.1.0/24", az_index = 1 }
    }
    private_subnets = {
      "app-a" = { cidr_block = "10.0.10.0/24", az_index = 0 }
      "app-b" = { cidr_block = "10.0.11.0/24", az_index = 1 }
    }
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1
    error_message = "Mode 'single' must create exactly one NAT gateway regardless of how many AZs have public subnets."
  }

  assert {
    condition     = length(aws_eip.nat) == 1
    error_message = "One Elastic IP per NAT gateway, and no more."
  }

  assert {
    condition     = length(aws_route.private_default_ipv4) == 2
    error_message = "Both private route tables must route 0.0.0.0/0 at the single shared NAT gateway."
  }
}

run "nat_per_az_creates_one_gateway_per_zone" {
  command = plan

  variables {
    nat_gateway_mode = "per_az"
    public_subnets = {
      "public-a" = { cidr_block = "10.0.0.0/24", az_index = 0 }
      "public-b" = { cidr_block = "10.0.1.0/24", az_index = 1 }
    }
    private_subnets = {
      "app-a" = { cidr_block = "10.0.10.0/24", az_index = 0 }
      "app-b" = { cidr_block = "10.0.11.0/24", az_index = 1 }
    }
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 2
    error_message = "Mode 'per_az' must create one NAT gateway per Availability Zone that has a public subnet."
  }
}

# -----------------------------------------------------------------------------
# IPv6
# -----------------------------------------------------------------------------
run "ipv6_adds_egress_only_gateway_not_nat" {
  command = plan

  variables {
    enable_ipv6                         = true
    enable_egress_only_internet_gateway = true
    public_subnets = {
      "public-a" = { cidr_block = "10.0.0.0/24", az_index = 0 }
    }
    private_subnets = {
      "app-a" = { cidr_block = "10.0.10.0/24", az_index = 0 }
    }
  }

  assert {
    condition     = aws_vpc.this.assign_generated_ipv6_cidr_block == true
    error_message = "enable_ipv6 must request an Amazon-provided IPv6 block."
  }

  assert {
    condition     = length(aws_egress_only_internet_gateway.this) == 1
    error_message = "IPv6 private egress uses an egress-only internet gateway, which is free, rather than a NAT gateway."
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 0
    error_message = "Enabling IPv6 must not create a chargeable NAT gateway."
  }

  assert {
    condition     = length(aws_route.private_default_ipv6) == 1 && aws_route.private_default_ipv6["0"].destination_ipv6_cidr_block == "::/0"
    error_message = "Private route tables must send ::/0 to the egress-only internet gateway."
  }

  assert {
    condition     = length(aws_route.public_default_ipv6) == 1
    error_message = "Public route tables must send ::/0 to the internet gateway."
  }
}

# -----------------------------------------------------------------------------
# Guard rails. Each of these should stop a learner before AWS returns a
# confusing error.
# -----------------------------------------------------------------------------
run "rejects_vpc_cidr_with_host_bits_set" {
  command = plan

  variables {
    cidr_block = "10.0.0.1/16"
  }

  expect_failures = [var.cidr_block]
}

run "rejects_vpc_cidr_larger_than_slash_16" {
  command = plan

  variables {
    cidr_block = "10.0.0.0/8"
  }

  expect_failures = [var.cidr_block]
}

run "rejects_subnet_outside_vpc_cidr" {
  command = plan

  variables {
    private_subnets = {
      "wrong" = { cidr_block = "192.168.1.0/24", az_index = 0 }
    }
  }

  expect_failures = [aws_vpc.this]
}

run "rejects_overlapping_subnets" {
  command = plan

  variables {
    private_subnets = {
      "a" = { cidr_block = "10.0.0.0/23", az_index = 0 }
      "b" = { cidr_block = "10.0.1.0/24", az_index = 1 }
    }
  }

  expect_failures = [aws_vpc.this]
}

run "rejects_az_index_beyond_available_zones" {
  command = plan

  variables {
    private_subnets = {
      "a" = { cidr_block = "10.0.0.0/24", az_index = 9 }
    }
  }

  expect_failures = [aws_vpc.this]
}

run "rejects_nat_gateway_without_public_subnet" {
  command = plan

  variables {
    nat_gateway_mode = "single"
    private_subnets = {
      "a" = { cidr_block = "10.0.0.0/24", az_index = 0 }
    }
  }

  expect_failures = [aws_vpc.this]
}

run "rejects_egress_only_gateway_without_ipv6" {
  command = plan

  variables {
    enable_ipv6                         = false
    enable_egress_only_internet_gateway = true
  }

  expect_failures = [var.enable_egress_only_internet_gateway]
}
