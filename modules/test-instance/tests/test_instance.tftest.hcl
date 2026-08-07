# Tests for modules/test-instance. Mocked provider, plan only: no credentials
# required, no instance launched.

mock_provider "aws" {
  mock_data "aws_ami" {
    defaults = {
      id           = "ami-0123456789abcdef0"
      architecture = "arm64"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }
}

variables {
  name      = "lab-host"
  vpc_id    = "vpc-0123456789abcdef0"
  subnet_id = "subnet-0123456789abcdef0"
}

run "secure_by_default" {
  command = plan

  assert {
    condition     = aws_instance.this.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be mandatory. IMDSv1 turns an SSRF bug into stolen instance credentials."
  }

  assert {
    condition     = aws_instance.this.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "The metadata hop limit must be 1 so a container on the instance cannot reach the metadata service through the host."
  }

  assert {
    condition     = aws_instance.this.root_block_device[0].encrypted == true
    error_message = "The root EBS volume must be encrypted."
  }

  assert {
    condition     = aws_instance.this.associate_public_ip_address == false
    error_message = "Instances must not get a public IP unless the caller asks for one."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.this) == 0
    error_message = "No inbound rules by default. Session Manager works over an outbound connection from the SSM agent."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.this) == 1
    error_message = "One default egress rule, which the SSM agent needs to reach Systems Manager."
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.ssm_core) == 1
    error_message = "Session Manager access requires AmazonSSMManagedInstanceCore on the instance role."
  }

  assert {
    condition     = aws_instance.this.instance_type == "t4g.nano"
    error_message = "Default instance type should be the cheapest option that runs the SSM agent."
  }

  assert {
    condition     = aws_instance.this.source_dest_check == true
    error_message = "Source/destination checking stays on for ordinary hosts; only forwarding appliances turn it off."
  }
}

run "no_ssm_means_no_iam_role" {
  command = plan

  variables {
    enable_ssm = false
  }

  assert {
    condition     = length(aws_iam_role.this) == 0
    error_message = "With SSM disabled and no additional policies there is nothing for an IAM role to grant."
  }

  assert {
    condition     = length(aws_iam_instance_profile.this) == 0
    error_message = "No instance profile should be created when no role exists."
  }
}

run "ingress_rules_are_created_from_the_map" {
  command = plan

  variables {
    ingress_rules = {
      icmp_from_vpc = {
        description = "ICMP echo from within the VPC, for ping tests"
        ip_protocol = "icmp"
        from_port   = 8
        to_port     = -1
        cidr_ipv4   = "10.0.0.0/16"
      }
    }
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.this["icmp_from_vpc"].cidr_ipv4 == "10.0.0.0/16"
    error_message = "Ingress rule source should come straight from the input map."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.this["icmp_from_vpc"].ip_protocol == "icmp"
    error_message = "Ingress rule protocol should come straight from the input map."
  }
}

run "rejects_public_ssh" {
  command = plan

  variables {
    ingress_rules = {
      ssh = {
        description = "SSH from anywhere"
        ip_protocol = "tcp"
        from_port   = 22
        to_port     = 22
        cidr_ipv4   = "0.0.0.0/0"
      }
    }
  }

  expect_failures = [var.ingress_rules]
}

run "rejects_rule_with_two_sources" {
  command = plan

  variables {
    ingress_rules = {
      confused = {
        description = "Two sources in one rule"
        ip_protocol = "tcp"
        from_port   = 443
        to_port     = 443
        cidr_ipv4   = "10.0.0.0/16"
        cidr_ipv6   = "::/0"
      }
    }
  }

  expect_failures = [var.ingress_rules]
}

run "rejects_architecture_mismatch" {
  command = plan

  variables {
    architecture  = "arm64"
    instance_type = "t3.micro"
  }

  expect_failures = [aws_instance.this]
}
