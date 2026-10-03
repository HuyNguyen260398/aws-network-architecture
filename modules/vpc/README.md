# `modules/vpc`

A VPC, its subnets, its route tables, and the gateways those route tables point
at.

## The idea this module exists to make visible

**A subnet is public because of its route table, not because of its name.**

```
public subnet   =  route table contains  0.0.0.0/0 -> internet gateway
private subnet  =  route table contains  0.0.0.0/0 -> NAT gateway   (outbound only)
isolated subnet =  route table contains  no default route at all
```

This module has no "isolated" subnet type on purpose. A private subnet with
`nat_gateway_mode = "none"` already is one. Adding a third name would obscure
the fact that the difference is one route.

## Usage

```hcl
module "vpc" {
  source = "../../modules/vpc"

  name       = "shop"
  cidr_block = "10.20.0.0/16"

  public_subnets = {
    "public-a" = { cidr_block = "10.20.0.0/24", az_index = 0, map_public_ip_on_launch = true }
    "public-b" = { cidr_block = "10.20.1.0/24", az_index = 1 }
  }

  private_subnets = {
    "app-a" = { cidr_block = "10.20.10.0/24", az_index = 0 }
    "app-b" = { cidr_block = "10.20.11.0/24", az_index = 1 }
  }

  nat_gateway_mode = "none"   # "single" or "per_az" cost money

  tags = local.common_tags
}
```

Subnets are a **map**, not a list. The keys become Terraform resource addresses
(`aws_subnet.private["app-a"]`), so adding or removing a subnet never shifts the
others. Renaming a key destroys and recreates that subnet.

## Cost

| Resource | Cost |
| --- | --- |
| VPC, subnets, route tables, security groups | Free |
| Internet gateway | Free to create; you pay for data out |
| Egress-only internet gateway | Free |
| NAT gateway (`nat_gateway_mode` ≠ `"none"`) | **~USD 0.059/hour ≈ USD 43/month, each**, plus ~USD 0.059/GB processed |
| Elastic IP attached to a NAT gateway | Included in the NAT charge |

`nat_gateway_mode` defaults to `"none"`. Nothing this module creates by default
costs money.

## Design decisions

**One shared public route table, one private route table per AZ.**
Every public subnet wants the same answer — send unknown traffic to the internet
gateway — so a single table is enough. Private subnets get a table each per AZ
because that is what makes `per_az` NAT and per-AZ inspection routing possible
later. Route tables are free, so the only cost is a slightly longer plan.

**AZs come from a data source.** `ap-southeast-1a` in your account is a
physically different zone from `ap-southeast-1a` in mine — AWS shuffles the
mapping per account. `az_index` indexes into `data.aws_availability_zones`,
filtered to zones that do not require opt-in, so the same configuration works
anywhere. Pass `availability_zones` to override.

**IPv6 uses an egress-only internet gateway, never NAT.** AWS has no IPv6 NAT.
Every IPv6 address is globally routable; the egress-only gateway supplies the
"outbound connections only" behaviour, and it is free.

**The default security group is stripped.** AWS creates it allowing all traffic
between members and all traffic outbound. Anything launched without an explicit
security group lands in it silently. `manage_default_security_group` removes
every rule.

**The main route table is kept empty.** A subnet with no explicit route table
association falls back to it, so an empty main table means a forgotten
association fails closed instead of quietly inheriting internet access.

## Built-in guard rails

The module refuses to plan when:

- a subnet CIDR falls outside the VPC CIDR
- two subnets overlap
- `az_index` exceeds the number of available AZs
- NAT is requested with no public subnets, or with no internet gateway
- the VPC CIDR has host bits set (`10.0.0.1/16`), which AWS silently normalises
  and which then shows as permanent drift
- the VPC CIDR is outside AWS's `/16`–`/28` range

The overlap and containment checks are done with integer arithmetic in
`locals.tf` — Terraform has no "does CIDR A contain CIDR B" function. Reading
that code is a decent refresher on how CIDR maths actually works.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `name` | `string` | — | Name prefix for every resource. |
| `cidr_block` | `string` | — | VPC IPv4 CIDR, `/16`–`/28`, network address only. |
| `availability_zones` | `list(string)` | `[]` | Override AZ discovery. |
| `public_subnets` | `map(object)` | `{}` | `cidr_block`, `az_index`, `map_public_ip_on_launch`, `ipv6_prefix_index`. |
| `private_subnets` | `map(object)` | `{}` | `cidr_block`, `az_index`, `ipv6_prefix_index`. |
| `create_internet_gateway` | `bool` | `true` | Set false for a fully private VPC. |
| `nat_gateway_mode` | `string` | `"none"` | `none`, `single`, or `per_az`. |
| `enable_ipv6` | `bool` | `false` | Request an Amazon-provided `/56`. |
| `enable_egress_only_internet_gateway` | `bool` | `false` | IPv6 outbound-only egress. Requires `enable_ipv6`. |
| `enable_dns_support` | `bool` | `true` | Amazon-provided resolver. Required for endpoint private DNS. |
| `enable_dns_hostnames` | `bool` | `true` | Required for endpoint private DNS. |
| `instance_tenancy` | `string` | `"default"` | Leave alone. `dedicated` is expensive and irreversible per instance. |
| `manage_default_security_group` | `bool` | `true` | Strip all rules from the default SG. |
| `manage_default_route_table` | `bool` | `true` | Keep the main route table empty. |
| `tags` | `map(string)` | `{}` | Applied to everything. |

## Outputs

`vpc_id`, `vpc_arn`, `vpc_cidr_block`, `vpc_ipv6_cidr_block`,
`default_security_group_id`, `availability_zones`, `public_subnet_ids`,
`private_subnet_ids`, `public_subnet_ids_list`, `private_subnet_ids_list`,
`public_subnets`, `private_subnets`, `internet_gateway_id`,
`egress_only_internet_gateway_id`, `public_route_table_id`,
`private_route_table_ids`, `all_route_table_ids`, `nat_gateway_ids`,
`nat_gateway_public_ips`, `nat_gateway_count`.

See `outputs.tf` for the description of each.

## Tests

```bash
terraform init -backend=false && terraform test
```

Twelve runs against a mocked provider. No AWS credentials, no API calls, nothing
created.

## Further reading

- [VPCs and subnets](https://docs.aws.amazon.com/vpc/latest/userguide/configure-your-vpc.html) — AWS
- [Route tables](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Route_Tables.html) — AWS
- [NAT gateways](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html) — AWS
- [IPv6 on Amazon VPC](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-migrate-ipv6.html) — AWS
- [VPC sizing and CIDR planning](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html) — AWS
