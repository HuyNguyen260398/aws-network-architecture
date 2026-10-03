# `modules/flow-logs`

VPC Flow Logs delivered to CloudWatch Logs or to S3.

## What flow logs tell you, and what they do not

Flow logs record **metadata** about IP traffic — source, destination, ports,
protocol, packet and byte counts, and an `action` of `ACCEPT` or `REJECT`. They
do not capture packet contents; that is traffic mirroring.

The `action` field is the reason this module earns its place in a troubleshooting
toolkit. When a connection fails:

| What you see | What it means |
| --- | --- |
| A `REJECT` record | A security group or network ACL dropped the packet. The packet arrived. |
| An `ACCEPT` outbound but nothing coming back | Usually a **network ACL** — it is stateless, so the return traffic needs its own inbound rule. |
| **No record at all** | The packet never reached the interface. Look at routing, not at filtering. |

That third case is the valuable one. Distinguishing "blocked" from "never
arrived" by inspection alone is guesswork; flow logs make it a lookup.

Note the asymmetry: a security group is stateful, so a rejected *inbound* packet
shows one `REJECT`. A network ACL is stateless, so a blocked *return* packet
shows an `ACCEPT` on the way out and a `REJECT` on the way back.

## Usage

```hcl
module "flow_logs" {
  source = "../../modules/flow-logs"

  name          = "shop"
  resource_type = "VPC"
  resource_id   = module.vpc.vpc_id

  traffic_type       = "ALL"
  log_retention_days = 1

  tags = local.common_tags
}
```

Then:

```bash
terraform output -raw flow_logs_tail_command | bash
```

## Cost

| Destination | Cost |
| --- | --- |
| CloudWatch Logs | ~USD 0.50/GB ingested + ~USD 0.03/GB-month stored |
| S3 | ~USD 0.25/GB delivered + S3 storage |

A quiet lab VPC generates single-digit megabytes per day, so cents. A busy VPC
with `traffic_type = "ALL"` can generate gigabytes. Two controls keep this small:

- `log_retention_days` defaults to **1**. A lab log group left at "never expire"
  keeps billing for storage long after the VPC is destroyed.
- `traffic_type = "REJECT"` captures only dropped traffic, which is a fraction of
  the volume and is often all a security investigation needs.
- `max_aggregation_interval` defaults to 600 seconds. Set it to 60 during an
  active troubleshooting session to get feedback faster, at the cost of more
  records.

## Custom log formats

The default (version 2) format omits some fields that matter once traffic is
translated. Adding them:

```hcl
log_format = "$${version} $${vpc-id} $${subnet-id} $${instance-id} $${interface-id} $${srcaddr} $${dstaddr} $${srcport} $${dstport} $${protocol} $${packets} $${bytes} $${start} $${end} $${action} $${log-status} $${pkt-srcaddr} $${pkt-dstaddr} $${flow-direction} $${traffic-path}"
```

`pkt-srcaddr` and `pkt-dstaddr` hold the **original** addresses, while `srcaddr`
and `dstaddr` hold the addresses at the interface being logged. Behind a NAT
gateway those differ, and without the `pkt-` fields every outbound flow appears
to come from the NAT gateway. `flow-direction` and `traffic-path` tell you which
way the flow went and whether it left via an internet gateway, a NAT gateway, a
Transit Gateway, or a VPN.

The `$${...}` doubling above is Terraform escaping — the file on disk contains
`${version}`, which is what AWS expects.

## Destinations

**CloudWatch Logs** creates the log group and an IAM role that VPC Flow Logs
assumes. The role's policy is scoped to that one log group, not `Resource: "*"`.

**S3** creates neither — S3 delivery is authorised by a bucket policy on the
destination bucket, which must already exist and permit
`delivery.logs.amazonaws.com`.

## Scope

`resource_type` picks what is captured:

- `VPC` — every interface in the VPC, including ones created later
- `Subnet` — every interface in one subnet
- `NetworkInterface` — one ENI, which is how you keep volume down when only one
  instance is interesting

## Inputs

| Name | Type | Default |
| --- | --- | --- |
| `name` | `string` | — |
| `resource_type` | `string` | `"VPC"` |
| `resource_id` | `string` | — |
| `traffic_type` | `string` | `"ALL"` |
| `destination_type` | `string` | `"cloud-watch-logs"` |
| `s3_bucket_arn` | `string` | `null` |
| `log_retention_days` | `number` | `1` |
| `kms_key_id` | `string` | `null` |
| `log_format` | `string` | `null` |
| `max_aggregation_interval` | `number` | `600` |
| `tags` | `map(string)` | `{}` |

## Outputs

`flow_log_id`, `flow_log_arn`, `log_group_name`, `log_group_arn`,
`iam_role_arn`, `tail_command`, `rejected_traffic_query`.

`rejected_traffic_query` is a ready-made CloudWatch Logs Insights query listing
recent rejected flows.

## Tests

```bash
terraform init -backend=false && terraform test
```

## Further reading

- [VPC Flow Logs](https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html) — AWS
- [Flow log record fields](https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html#flow-logs-fields) — AWS
- [Flow log record examples](https://docs.aws.amazon.com/vpc/latest/userguide/flow-log-records.html) — AWS
- [CloudWatch Logs Insights query syntax](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL_QuerySyntax.html) — AWS
