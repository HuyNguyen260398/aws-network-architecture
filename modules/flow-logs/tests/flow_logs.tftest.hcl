# Tests for modules/flow-logs. Mocked provider, plan only.

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }
}

variables {
  name        = "lab08"
  resource_id = "vpc-0123456789abcdef0"
}

run "cloudwatch_defaults" {
  command = plan

  assert {
    condition     = aws_flow_log.this.traffic_type == "ALL"
    error_message = "Default traffic_type should capture both accepted and rejected flows."
  }

  assert {
    condition     = aws_flow_log.this.vpc_id == "vpc-0123456789abcdef0"
    error_message = "resource_type VPC must map resource_id onto vpc_id."
  }

  assert {
    condition     = aws_flow_log.this.subnet_id == null && aws_flow_log.this.eni_id == null
    error_message = "Only the attribute matching resource_type may be set; setting more than one is rejected by the API."
  }

  assert {
    condition     = aws_cloudwatch_log_group.this[0].retention_in_days == 1
    error_message = "Lab log groups must default to a short retention so a forgotten lab does not keep billing for storage."
  }

  assert {
    condition     = aws_flow_log.this.max_aggregation_interval == 600
    error_message = "Default aggregation interval should be the cheaper 600 seconds."
  }

  assert {
    condition     = length(aws_iam_role.this) == 1
    error_message = "CloudWatch delivery needs a role that VPC Flow Logs can assume."
  }
}

run "eni_scope" {
  command = plan

  variables {
    resource_type = "NetworkInterface"
    resource_id   = "eni-0123456789abcdef0"
    traffic_type  = "REJECT"
  }

  assert {
    condition     = aws_flow_log.this.eni_id == "eni-0123456789abcdef0"
    error_message = "resource_type NetworkInterface must map resource_id onto eni_id."
  }

  assert {
    condition     = aws_flow_log.this.vpc_id == null
    error_message = "vpc_id must be unset when scoping to a single interface."
  }

  assert {
    condition     = aws_flow_log.this.traffic_type == "REJECT"
    error_message = "traffic_type must be honoured."
  }
}

run "s3_destination_creates_no_log_group_or_role" {
  command = plan

  variables {
    destination_type = "s3"
    s3_bucket_arn    = "arn:aws:s3:::example-flow-logs"
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.this) == 0
    error_message = "S3 delivery must not create a CloudWatch log group."
  }

  assert {
    condition     = length(aws_iam_role.this) == 0
    error_message = "S3 delivery is authorised by a bucket policy, not by a delivery role."
  }

  assert {
    condition     = aws_flow_log.this.log_destination == "arn:aws:s3:::example-flow-logs"
    error_message = "S3 delivery must target the supplied bucket ARN."
  }
}

run "rejects_s3_destination_without_bucket" {
  command = plan

  variables {
    destination_type = "s3"
  }

  expect_failures = [aws_flow_log.this]
}

run "rejects_invalid_retention" {
  command = plan

  variables {
    log_retention_days = 2
  }

  expect_failures = [var.log_retention_days]
}
