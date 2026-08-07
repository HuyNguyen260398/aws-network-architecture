# `modules/test-instance`

A disposable EC2 host for proving that networking works: ping a peer, `curl` an
endpoint, `dig` a private hosted zone record, watch a flow log entry appear.

## No SSH. Ever.

There is no key pair, no port 22 ingress rule, and no bastion host. Shell access
is through **AWS Systems Manager Session Manager**:

```bash
aws ssm start-session --target i-0123456789abcdef0 --region ap-southeast-1
```

The module's `ssm_start_session_command` output prints exactly that line.

This is not only a security preference. The SSM agent makes an **outbound**
connection to the Systems Manager service and the session is carried back over
it, which means:

- the instance needs **zero inbound rules** (security groups are stateful, so
  the reply traffic is allowed automatically)
- the same module works in a fully private subnet with no internet route at all,
  provided the `ssm`, `ssmmessages` and `ec2messages` interface endpoints exist
- there is no key material to generate, store, rotate, or accidentally commit

The `ingress_rules` variable refuses a rule that opens port 22 to `0.0.0.0/0`.

## What the instance needs to reach Systems Manager

Session Manager fails silently — the instance simply never appears in
`aws ssm describe-instance-information` — if the network path is missing. One of
these must be true:

| Placement | Requirement |
| --- | --- |
| Public subnet | `associate_public_ip_address = true` and a `0.0.0.0/0` route to an internet gateway |
| Private subnet + NAT | A `0.0.0.0/0` route to a NAT gateway (~USD 43/month) |
| Private subnet, no NAT | Interface endpoints for `ssm`, `ssmmessages`, `ec2messages` (~USD 8/month per ENI) |

Registration takes one to three minutes after launch.

## Usage

```hcl
module "host" {
  source = "../../modules/test-instance"

  name      = "lab02-private-a"
  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.private_subnet_ids["app-a"]

  # Allow ping from within the VPC so connectivity tests work.
  ingress_rules = {
    icmp_from_vpc = {
      description = "ICMP echo from within the VPC"
      ip_protocol = "icmp"
      from_port   = 8
      to_port     = -1
      cidr_ipv4   = module.vpc.vpc_cidr_block
    }
  }

  tags = local.common_tags
}
```

## Cost

| Item | Cost in ap-southeast-1 |
| --- | --- |
| `t4g.nano` instance | ~USD 0.0053/hour ≈ USD 3.90/month |
| 8 GB gp3 root volume | ~USD 0.77/month |
| Public IPv4 address (`associate_public_ip_address = true`) | ~USD 0.005/hour ≈ USD 3.60/month |
| Detailed monitoring (opt-in) | ~USD 2.10/month |

A lab you destroy the same day costs cents. `t4g.nano` is Graviton, so
`architecture` must stay `arm64`; the module has a precondition that catches a
mismatch before AWS returns `InvalidParameterValue`.

## Security properties

| Property | Setting |
| --- | --- |
| IMDSv2 required | `http_tokens = "required"` — closes the SSRF-to-credentials path |
| Metadata hop limit | `1` — a container on the host cannot reach IMDS through the host |
| Root volume encrypted | `encrypted = true`, gp3 |
| Public IP | Off unless explicitly requested |
| Inbound rules | None by default |
| IAM | `AmazonSSMManagedInstanceCore` only |
| Instance metadata tags | Enabled, so scripts can read the instance's own tags |

Security group rules are separate `aws_vpc_security_group_ingress_rule`
resources rather than inline blocks. Inline blocks are authoritative for the
whole group, so a rule someone adds in the console is silently deleted on the
next apply — confusing behaviour in the middle of a troubleshooting lab.

## Notable inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `name` | `string` | — | Name prefix. |
| `vpc_id` | `string` | — | VPC for the security group. |
| `subnet_id` | `string` | — | Where to launch. Determines SSM reachability. |
| `instance_type` | `string` | `"t4g.nano"` | Must match `architecture`. |
| `architecture` | `string` | `"arm64"` | `arm64` or `x86_64`. |
| `ami_id` | `string` | `null` | Override the AL2023 lookup. |
| `associate_public_ip_address` | `bool` | `false` | Billed hourly. |
| `enable_ssm` | `bool` | `true` | Create the Session Manager role. |
| `ingress_rules` | `map(object)` | `{}` | Exactly one source per rule. |
| `egress_rules` | `map(object)` | all IPv4 out | SSM agent needs outbound. |
| `user_data` | `string` | `null` | Never put secrets here — IMDS exposes it. |
| `source_dest_check` | `bool` | `true` | Set false for a forwarding appliance. |
| `root_volume_size_gb` | `number` | `8` | 8–100. |

See `variables.tf` for the rest.

## AMI selection

The module queries `DescribeImages` for
`al2023-ami-2023.*-kernel-6.1-<architecture>` owned by `amazon`, rather than
reading the `/aws/service/ami-al2023/...` SSM public parameters. Both are data
sources, but some restricted IAM policies deny the entire `/aws/` Parameter
Store namespace, and the failure mode is an opaque
`No access to "/aws/" namespace`. `DescribeImages` needs only `ec2:DescribeImages`.

## Tests

```bash
terraform init -backend=false && terraform test
```

## Further reading

- [Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html) — AWS
- [Session Manager prerequisites](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-prerequisites.html) — AWS
- [Instance metadata service v2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html) — AWS
- [Security group rules](https://docs.aws.amazon.com/vpc/latest/userguide/security-group-rules.html) — AWS
