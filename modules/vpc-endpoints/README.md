# `modules/vpc-endpoints`

Gateway and interface VPC endpoints, so a private subnet can reach AWS services
without a route to the internet.

## Two mechanisms, same goal

|  | Gateway endpoint | Interface endpoint |
| --- | --- | --- |
| Services | S3 and DynamoDB only | Almost every other AWS service |
| Implementation | A **route** to a managed prefix list | An **ENI** in your subnet with a private IP |
| Security group | None — it is not an addressable thing | Yes, TCP 443 |
| DNS | Unchanged; routing does the work | Optionally hijacks the public hostname inside the VPC |
| Reachable from on-premises over VPN/DX | **No** | **Yes** |
| Reachable from a peered VPC | **No** | Yes, with cross-VPC DNS work |
| Cost | **Free** | ~USD 0.011/ENI-hour ≈ USD 8/ENI/month + ~USD 0.01/GB |

The on-premises row is usually what decides a design. A gateway endpoint is
purely a route table entry inside one VPC; nothing outside that VPC can use it.
An interface endpoint is an ordinary private IP address in your CIDR, so
anything that can reach your VPC can reach it.

## The NAT gateway trade-off

This is the calculation worth internalising:

```
NAT gateway     USD 0.059/hour  (~USD 43/month)  + USD 0.059/GB processed
S3 gateway VPCE USD 0           + USD 0
S3 interface    USD 0.011/ENI-hour (~USD 8/month) + USD 0.01/GB
```

If a private subnet's outbound traffic is only ever to S3, an S3 **gateway**
endpoint replaces the NAT gateway completely and costs nothing. If it also needs
SSM, three interface endpoints in one subnet (~USD 24/month) still beat a NAT
gateway, and keep the traffic off the public internet entirely.

A NAT gateway wins when the workload talks to many different services, or to the
actual internet, and you would otherwise need a dozen interface endpoints.

## Usage

```hcl
module "endpoints" {
  source = "../../modules/vpc-endpoints"

  name   = "shop"
  vpc_id = module.vpc.vpc_id

  # Free. Must be attached to the route tables of the subnets that will use it.
  gateway_endpoints                = { s3 = {} }
  gateway_endpoint_route_table_ids = module.vpc.all_route_table_ids

  # Chargeable. One subnet is enough for a lab.
  interface_endpoints = {
    ssm         = {}
    ssmmessages = {}
    ec2messages = {}
  }
  interface_endpoint_subnet_ids = [module.vpc.private_subnet_ids["app-a"]]
  allowed_cidr_blocks           = [module.vpc.vpc_cidr_block]

  tags = local.common_tags
}
```

## Endpoint policies

`policy` on either endpoint type restricts what can be reached **through** that
endpoint. It does not grant anything — the caller's IAM policy and the endpoint
policy must both allow the call. Omitting it means full access, which is the AWS
default.

A policy that limits an S3 gateway endpoint to one bucket:

```hcl
gateway_endpoints = {
  s3 = {
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:GetObject", "s3:ListBucket"]
        Resource  = ["arn:aws:s3:::my-bucket", "arn:aws:s3:::my-bucket/*"]
      }]
    })
  }
}
```

This is a common exam and interview topic because it is the mechanism that stops
data being exfiltrated to an S3 bucket in someone else's account from inside
your VPC.

## Private DNS

With `private_dns_enabled = true` (the default), the endpoint takes over the
service's public hostname inside the VPC: `ssm.ap-southeast-1.amazonaws.com`
resolves to the endpoint ENI's private address. Unmodified SDKs and the AWS CLI
then use the endpoint with no configuration change.

It requires `enable_dns_support` **and** `enable_dns_hostnames` on the VPC.
`modules/vpc` defaults both to true. With them off, the endpoint is created
successfully and then quietly does nothing, because the service hostname still
resolves to a public address.

## Built-in guard rails

- A gateway endpoint with no route tables is rejected. It is the most common
  reason "the endpoint does not work" — with no association, traffic keeps
  following the default route.
- `s3` and `dynamodb` are the only accepted gateway services.
- An interface endpoint with no subnet, or no security group, is rejected.
- Endpoint policies must be valid JSON.
- Service names are resolved through `data.aws_vpc_endpoint_service`, so a typo
  fails at plan time rather than at apply time.

## Notable inputs

| Name | Type | Default |
| --- | --- | --- |
| `name` | `string` | — |
| `vpc_id` | `string` | — |
| `gateway_endpoints` | `map(object({policy}))` | `{}` |
| `gateway_endpoint_route_table_ids` | `list(string)` | `[]` |
| `interface_endpoints` | `map(object({private_dns_enabled, subnet_ids, security_group_ids, policy, ip_address_type}))` | `{}` |
| `interface_endpoint_subnet_ids` | `list(string)` | `[]` |
| `create_security_group` | `bool` | `true` |
| `allowed_cidr_blocks` | `list(string)` | `[]` |

## Outputs

`gateway_endpoint_ids`, `gateway_endpoint_prefix_list_ids`,
`interface_endpoint_ids`, `interface_endpoint_dns_entries`,
`interface_endpoint_network_interface_ids`, `endpoint_security_group_id`,
`interface_endpoint_eni_count`, `estimated_monthly_cost_usd`.

`gateway_endpoint_prefix_list_ids` is worth knowing about: you can reference a
prefix list in a security group rule to allow traffic to S3 without hardcoding
AWS IP ranges that change.

## Tests

```bash
terraform init -backend=false && terraform test
```

## Further reading

- [Gateway endpoints](https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html) — AWS
- [Interface endpoints](https://docs.aws.amazon.com/vpc/latest/privatelink/create-interface-endpoint.html) — AWS
- [Endpoint policies](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-access.html) — AWS
- [Systems Manager VPC endpoints](https://docs.aws.amazon.com/systems-manager/latest/userguide/setup-create-vpc.html) — AWS
- [AWS PrivateLink pricing](https://aws.amazon.com/privatelink/pricing/) — AWS
