# Tests for modules/vpc-endpoints. Mocked provider, plan only.

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }

  mock_data "aws_vpc_endpoint_service" {
    defaults = {
      service_name = "com.amazonaws.ap-southeast-1.mocked"
    }
  }
}

variables {
  name   = "lab03"
  vpc_id = "vpc-0123456789abcdef0"
}

run "nothing_by_default" {
  command = plan

  assert {
    condition     = length(aws_vpc_endpoint.gateway) == 0 && length(aws_vpc_endpoint.interface) == 0
    error_message = "The module must create nothing until endpoints are requested."
  }

  assert {
    condition     = length(aws_security_group.endpoints) == 0
    error_message = "No endpoint security group is needed when there are no interface endpoints."
  }
}

run "gateway_endpoint_is_free_and_needs_route_tables" {
  command = plan

  variables {
    gateway_endpoints                = { s3 = {} }
    gateway_endpoint_route_table_ids = ["rtb-0123456789abcdef0"]
  }

  assert {
    condition     = aws_vpc_endpoint.gateway["s3"].vpc_endpoint_type == "Gateway"
    error_message = "S3 must use a gateway endpoint, not an interface endpoint."
  }

  assert {
    condition     = length(aws_vpc_endpoint.gateway["s3"].route_table_ids) == 1
    error_message = "The gateway endpoint must be associated with the supplied route table."
  }

  assert {
    condition     = length(aws_security_group.endpoints) == 0
    error_message = "Gateway endpoints have no ENI and therefore no security group."
  }
}

run "rejects_gateway_endpoint_with_no_route_tables" {
  command = plan

  variables {
    gateway_endpoints = { s3 = {} }
  }

  expect_failures = [aws_vpc_endpoint.gateway]
}

run "rejects_interface_only_service_as_gateway" {
  command = plan

  variables {
    gateway_endpoints = { ssm = {} }
  }

  expect_failures = [var.gateway_endpoints]
}

run "interface_endpoints_get_a_security_group" {
  command = plan

  variables {
    interface_endpoints = {
      ssm         = {}
      ssmmessages = {}
      ec2messages = {}
    }
    interface_endpoint_subnet_ids = ["subnet-0123456789abcdef0"]
    allowed_cidr_blocks           = ["10.0.0.0/16"]
  }

  assert {
    condition     = length(aws_vpc_endpoint.interface) == 3
    error_message = "Session Manager in a private subnet needs all three of ssm, ssmmessages and ec2messages."
  }

  assert {
    condition     = aws_vpc_endpoint.interface["ssm"].private_dns_enabled == true
    error_message = "Private DNS should default to on, so unmodified SDK calls use the endpoint."
  }

  assert {
    condition     = length(aws_security_group.endpoints) == 1
    error_message = "One shared security group should be created for the interface endpoints."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.https["10.0.0.0/16"].to_port == 443
    error_message = "Interface endpoints speak HTTPS only; nothing but 443 should be opened."
  }
}

run "rejects_interface_endpoint_without_subnets" {
  command = plan

  variables {
    interface_endpoints = { ssm = {} }
    allowed_cidr_blocks = ["10.0.0.0/16"]
  }

  expect_failures = [aws_vpc_endpoint.interface]
}

run "rejects_invalid_endpoint_policy_json" {
  command = plan

  variables {
    gateway_endpoints = {
      s3 = { policy = "this is not json" }
    }
    gateway_endpoint_route_table_ids = ["rtb-0123456789abcdef0"]
  }

  expect_failures = [var.gateway_endpoints]
}
