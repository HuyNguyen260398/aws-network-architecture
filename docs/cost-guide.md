# Cost guide

Every price here is **ap-southeast-1 (Singapore) on-demand list price**, checked
against AWS pricing pages while this repository was written. Prices change and
differ by Region — treat these as the right order of magnitude, not as a quote.
[The AWS Pricing Calculator](https://calculator.aws/) is authoritative.

---

## The short version

**Free, always:** VPCs, subnets, route tables, internet gateways, egress-only
internet gateways, security groups, network ACLs, VPC peering connections,
gateway VPC endpoints, customer gateways, virtual private gateways, Direct
Connect gateways (with no virtual interfaces), Transit Gateways themselves,
DHCP option sets.

**The six things that cost real money in a learning account:**

| Resource | Per hour | Per month | Where |
| --- | --- | --- | --- |
| **AWS Network Firewall endpoint** | **USD 0.395** | **~USD 288** | Lab 08 |
| **Route 53 Resolver endpoint** (2 mandatory ENIs) | **USD 0.25** | **~USD 180** | Lab 11 |
| **EKS cluster** (control plane; nodes and load balancer extra) | **USD 0.10** | **~USD 73** | Lab 07 |
| **NAT gateway** | USD 0.059 | ~USD 43 | Lab 03 |
| **Transit Gateway attachment**, each | USD 0.05 | ~USD 36 | Labs 10, 13 |
| **Site-to-Site VPN connection** | USD 0.05 | ~USD 36 | Lab 12 |

All six are **off by default** and require both a feature flag and
`acknowledge_costs = true`.

**The labs share one deployment, so costs accumulate.** A flag switched on in
lab 03 is still on in lab 09 unless you switch it off. See
[`working-with-the-labs.md`](working-with-the-labs.md#cost-everything-accumulates).

--- | --- | --- | --- |
| **AWS Network Firewall endpoint** | **USD 0.395** | **~USD 288** | Lab 08 |
| **Route 53 Resolver endpoint** (2 mandatory ENIs) | **USD 0.25** | **~USD 180** | Lab 06 |
| **NAT gateway** | USD 0.059 | ~USD 43 | Lab 02 |
| **Transit Gateway attachment**, each | USD 0.05 | ~USD 36 | Labs 05, 07, 09 |
| **Site-to-Site VPN connection** | USD 0.05 | ~USD 36 | Lab 07 |

All five are **off by default** and require both a feature flag and
`acknowledge_costs = true`.

---

## Full price table

### Free

| Resource | Note |
| --- | --- |
| VPC, subnets, route tables | No charge, ever |
| Internet gateway | Free to create and keep; you pay for data out |
| Egress-only internet gateway | Completely free — the IPv6 "NAT" alternative |
| Security groups, network ACLs | Free |
| **VPC peering connection** | Free to create; you pay only for data crossing it |
| **Gateway VPC endpoint** (S3, DynamoDB) | **Free.** No hourly charge, no data charge |
| Customer gateway | Just a record of an IP and an ASN |
| Virtual private gateway | Free; the VPN *connection* is what costs |
| **Direct Connect gateway** | Free with no virtual interfaces attached |
| Transit Gateway (the gateway) | Free; the **attachments** cost |
| Elastic IP **while attached** to a running instance | Charged only when idle or as a second address |
| AWS Shield Standard | Free and automatic for every AWS customer |

### Hourly

| Resource | Per hour | Per month | Notes |
| --- | --- | --- | --- |
| AWS Network Firewall endpoint | USD 0.395 | ~USD 288 | Per endpoint, per AZ |
| Route 53 Resolver endpoint | USD 0.125/ENI | ~USD 180 | **Minimum 2 ENIs.** No cheaper option |
| NAT gateway | USD 0.059 | ~USD 43 | Per gateway |
| Transit Gateway attachment | USD 0.05 | ~USD 36 | Per attachment |
| Site-to-Site VPN connection | USD 0.05 | ~USD 36 | Billed from creation, even if tunnels are DOWN |
| Client VPN endpoint association | USD 0.15 | ~USD 110 | Not used in this repository |
| AWS Global Accelerator | USD 0.025 | ~USD 18 | Fixed, regardless of traffic |
| Network Load Balancer | USD 0.0225 | ~USD 16 | Plus LCU charges |
| Interface VPC endpoint | USD 0.011/ENI | ~USD 8 | Per ENI, so per subnet |
| Public IPv4 address | USD 0.005 | ~USD 3.60 | Charged whether in use or not, since Feb 2024 |
| **Idle Elastic IP** | USD 0.005 | ~USD 3.60 | The classic leftover |
| `t4g.nano` | USD 0.0053 | ~USD 3.90 | The instance this repository uses |
| `t4g.small` | USD 0.0212 | ~USD 15.50 | Lab 12's VPN router |

### Per gigabyte

| Path | Cost | Notes |
| --- | --- | --- |
| NAT gateway processing | ~USD 0.059/GB | **On top of** the hourly charge |
| Network Firewall processing | ~USD 0.065/GB | On top of USD 0.395/hour |
| Transit Gateway processing | ~USD 0.02/GB | Per GB, per attachment traversed |
| Inter-Region data transfer | ~USD 0.02/GB | **Each direction** |
| VPC peering, same Region, cross-AZ | ~USD 0.01/GB | Each direction; free within one AZ |
| Cross-AZ data transfer | ~USD 0.01/GB | Each direction |
| Interface endpoint processing | ~USD 0.01/GB | |
| Internet egress | ~USD 0.09/GB | First 100 GB/month free account-wide |
| **Internet ingress** | **Free** | |

### Per unit

| Item | Cost |
| --- | --- |
| Reachability Analyzer analysis | **USD 0.10 each** (paths are free) |
| Route 53 hosted zone | USD 0.50/month, public or private |
| Route 53 queries | USD 0.40 per million |
| Route 53 health check (AWS endpoint) | USD 0.50/month |
| CloudWatch Logs ingestion | ~USD 0.50/GB |
| CloudWatch Logs storage | ~USD 0.03/GB-month |
| Flow logs to S3 | ~USD 0.25/GB delivered |
| CloudWatch alarm | USD 0.10/month |
| AWS Budgets | First 2 free |
| **AWS Shield Advanced** | **USD 3,000/month**, 1-year commitment |

---

## Cost per lab

"Adds by default" is what the lab adds with every opt-in off. "Opt-ins" is
what each of that lab's flags adds while it is on.

| Lab | Adds by default | Opt-ins | The expensive part |
| --- | --- | --- | --- |
| 01 Single server | ~USD 0.010/hr | — | One instance and its public IPv4 |
| 02 Segmentation | ~USD 0.011/hr | — | Two more instances |
| 03 NAT | — | ~USD 0.059/hr | NAT gateway |
| 04 Private AWS access | Free | ~USD 0.033/hr | 3 interface endpoints |
| 05 Load balancing | — | ~USD 0.035/hr | ALB and its two public IPv4 addresses |
| 06 Containers | ~USD 0.016/hr | ~USD 0.024/hr | Docker host; 2 Fargate tasks |
| 07 Kubernetes | — | **~USD 0.20–0.25/hr** | EKS control plane, nodes, Ingress ALB (and needs NAT) |
| 08 Security/observability | cents | **~USD 0.395/hr** | Network Firewall |
| 09 VPC peering | ~USD 0.021/hr | — | Two more instances |
| 10 Transit Gateway | — | **~USD 0.15/hr** | 3 attachments |
| 11 DNS and PrivateLink | cents | ~USD 0.036/hr · **USD 0.25/hr each** | NLB + endpoint; Resolver endpoints |
| 12 Hybrid networking | Free | ~USD 0.076/hr | VPN + office router |
| 13 Multi-Region | ~USD 0.010/hr | ~USD 0.10/hr | 2 more TGW attachments |
| 14 Troubleshooting | — | ~USD 0.010/hr for two challenges | One more instance |

**Running total with every opt-in off: about USD 0.07/hour at lab 14** —
USD 1.70 a day. With every opt-in on at once: over USD 1.60/hour.

**Working through every lab, turning opt-ins off as you go, costs under
USD 5.**

Each lab's README states its costs, and the expensive opt-ins print a
warning on every `terraform plan` while they are on.

---

## The three decisions worth understanding

### NAT gateway or VPC endpoints?

```
NAT gateway         USD 43/month  + USD 0.059/GB    reaches everything
S3 gateway endpoint USD 0         + USD 0           S3 only, this VPC only
Interface endpoint  USD 8/month   + USD 0.01/GB     one service, reachable from anywhere
```

| Your private subnet needs | Cheapest correct answer |
| --- | --- |
| S3 and/or DynamoDB only | **Gateway endpoints. Free.** Always do this regardless. |
| Systems Manager only | 3 interface endpoints, ~USD 24/month |
| Up to ~5 AWS services | Interface endpoints |
| More than ~5 services | NAT gateway becomes cheaper |
| The actual internet | NAT gateway — nothing else works |
| IPv6 outbound only | **Egress-only internet gateway. Free.** |

Gateway endpoints for S3 and DynamoDB are free and strictly better than routing
that traffic through a NAT gateway. There is no configuration in which you
should not have them.

### VPC peering, Transit Gateway or PrivateLink?

| VPCs | Peering | Transit Gateway | Winner |
| --- | --- | --- | --- |
| 2 | Free, 1 connection | USD 72/month, 2 attachments | **Peering** |
| 4 | Free, 6 connections | USD 144/month | Peering on cost, TGW on sanity |
| 10 | Free, **45 connections, 90 routes** | USD 360/month | **Transit Gateway** |

Peering is free and does not scale. Transit Gateway costs money and does. The
crossover is operational rather than financial — around four or five VPCs the
route table maintenance stops being worth the saving.

**PrivateLink** is a different question, not a cheaper Transit Gateway. If the
requirement is "team X calls team Y's API" rather than "these networks must be
joined", it is ~USD 8/month per consumer, needs no address coordination, works
with overlapping CIDRs, and is unidirectional by design.

### One NAT gateway or one per AZ?

| | `single` | `per_az` |
| --- | --- | --- |
| 2 AZs | ~USD 43/month | ~USD 86/month |
| 3 AZs | ~USD 43/month | ~USD 129/month |
| An AZ fails | Other AZs lose outbound access | Unaffected |
| Cross-AZ data charge | ~USD 0.01/GB each way | None |

At roughly 4 TB/month of cross-AZ NAT traffic, the transfer charge alone exceeds
the second gateway. For a lab, `single` is always right.

---

## Cleanup checklist

Run this after finishing any lab. `terraform destroy` handles the normal path;
this catches partial failures and resources created by hand.

```bash
#!/usr/bin/env bash
# Sweep for chargeable networking resources. Read-only.
REGIONS="ap-southeast-1 ap-northeast-1"

for R in $REGIONS; do
  echo "════════ $R ════════"

  echo "-- NAT gateways (~USD 43/mo each) --"
  aws ec2 describe-nat-gateways --region "$R" \
    --filter Name=state,Values=available,pending \
    --query 'NatGateways[].[NatGatewayId,VpcId]' --output text

  echo "-- Idle Elastic IPs (~USD 3.60/mo each) --"
  aws ec2 describe-addresses --region "$R" \
    --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' --output text

  echo "-- Transit Gateway attachments (~USD 36/mo each) --"
  aws ec2 describe-transit-gateway-attachments --region "$R" \
    --query 'TransitGatewayAttachments[?State==`available`].[TransitGatewayAttachmentId,ResourceType]' --output text

  echo "-- VPN connections (~USD 36/mo each) --"
  aws ec2 describe-vpn-connections --region "$R" \
    --query 'VpnConnections[?State==`available`].[VpnConnectionId,State]' --output text

  echo "-- Interface endpoints (~USD 8/mo per ENI) --"
  aws ec2 describe-vpc-endpoints --region "$R" \
    --filters Name=vpc-endpoint-type,Values=Interface \
    --query 'VpcEndpoints[?State==`available`].[VpcEndpointId,ServiceName]' --output text

  echo "-- Network Firewalls (~USD 288/mo each) --"
  aws network-firewall list-firewalls --region "$R" \
    --query 'Firewalls[].[FirewallName]' --output text 2>/dev/null

  echo "-- Route 53 Resolver endpoints (~USD 180/mo each) --"
  aws route53resolver list-resolver-endpoints --region "$R" \
    --query 'ResolverEndpoints[?Status!=`DELETING`].[Id,Name,Direction]' --output text 2>/dev/null

  echo "-- Load balancers --"
  aws elbv2 describe-load-balancers --region "$R" \
    --query 'LoadBalancers[].[LoadBalancerName,Type]' --output text 2>/dev/null

  echo "-- Running instances --"
  aws ec2 describe-instances --region "$R" \
    --filters Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType]' --output text

  echo "-- Log groups from this repository --"
  aws logs describe-log-groups --region "$R" \
    --query 'logGroups[?starts_with(logGroupName, `/aws/vpc-flow-logs`) || starts_with(logGroupName, `/aws/network-firewall`)].[logGroupName,retentionInDays]' \
    --output text
  echo
done

echo "-- Route 53 hosted zones (USD 0.50/mo each) --"
aws route53 list-hosted-zones --query 'HostedZones[].[Id,Name,Config.PrivateZone]' --output text

echo "-- Route 53 health checks (USD 0.50/mo each) --"
aws route53 list-health-checks --query 'HealthChecks[].[Id,HealthCheckConfig.Type]' --output text
```

Save it as `sweep.sh` and run it whenever you finish a session.

### Sweep by tag instead

Every resource this repository creates carries `Project`, `Lab` and
`ManagedBy = terraform`:

```bash
aws resourcegroupstaggingapi get-resources \
  --region ap-southeast-1 \
  --tag-filters Key=Project,Values=awsnet \
  --query 'ResourceTagMappingList[].ResourceARN' --output text
```

### What survives a partial destroy

| Resource | Why |
| --- | --- |
| **Elastic IPs** | Detached from a deleted NAT gateway, still allocated, still billed |
| **CloudWatch log groups** | Not owned by the VPC; retention keeps billing storage |
| **S3 buckets with objects** | Terraform cannot delete a non-empty bucket without `force_destroy` |
| **Route 53 hosted zones** | A VPC association can block deletion |
| **Network Insights paths** | Free, but they accumulate |
| **Transit Gateway attachments** | Deletion is slow; a timeout can leave one behind |
| **VPN connections** | Same |
| **CloudTrail trails** | Account-wide, not VPC-scoped |
| **Network Firewalls** | `delete_protection` blocks destroy if enabled |

The first four are the common ones. **An idle Elastic IP is the classic
leftover** — it costs money precisely because it is not attached to anything.

---

## Guard rails in this repository

**Two keys for anything expensive.** Both a feature flag and
`acknowledge_costs = true`:

```hcl
variable "enable_nat_gateway" {
  type    = bool
  default = false
  validation {
    condition     = !var.enable_nat_gateway || var.acknowledge_costs
    error_message = "Set acknowledge_costs = true to create hourly-billed resources."
  }
}
```

**Warnings while it is on.** The most expensive opt-ins have a `check` block
that prints a cost warning on every `terraform plan` until they are turned
off. The cheapest state — with nothing connected — warns too, so the plan
always says which of the two you are in.

**Small defaults.** `t4g.nano`, one-day log retention, single-AZ NAT, one subnet
for interface endpoints, no detailed monitoring, no Elastic IPs unless a NAT
gateway or VPN demands one.

**A budget.** `bootstrap/` can create one:

```hcl
enable_budget              = true
budget_limit_usd           = 20
budget_notification_emails = ["you@example.com"]
```

The first two budgets per account are free. The **forecast** alert is the useful
one — it fires on projected spend, so a resource left running overnight is caught
in hours rather than at month end.

---

## If you find an unexpected charge

```bash
# Yesterday's spend by service
aws ce get-cost-and-usage \
  --time-period Start=$(date -u -d '2 days ago' +%Y-%m-%d),End=$(date -u +%Y-%m-%d) \
  --granularity DAILY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[-1].Groups[?Metrics.UnblendedCost.Amount!=`0`].[Keys[0],Metrics.UnblendedCost.Amount]' \
  --output table
```

Cost Explorer API calls cost USD 0.01 each. What to look for:

| Line item | Usual cause |
| --- | --- |
| `EC2 - Other` | NAT gateway hours or data processing, or cross-AZ transfer |
| `Amazon Virtual Private Cloud` | VPN connections, interface endpoints, public IPv4 addresses |
| `AWS Transit Gateway` | Attachments |
| `AWS Network Firewall` | The single most expensive mistake here |
| `Amazon Route 53` | Resolver endpoints, or hosted zones |

`EC2 - Other` is the one that puzzles people. It is where NAT gateway data
processing and cross-AZ transfer land, and it has no obvious connection to any
resource in the console.

---

## Sources

- [Amazon VPC pricing](https://aws.amazon.com/vpc/pricing/)
- [AWS Transit Gateway pricing](https://aws.amazon.com/transit-gateway/pricing/)
- [AWS PrivateLink pricing](https://aws.amazon.com/privatelink/pricing/)
- [AWS Site-to-Site VPN pricing](https://aws.amazon.com/vpn/pricing/)
- [AWS Network Firewall pricing](https://aws.amazon.com/network-firewall/pricing/)
- [Amazon Route 53 pricing](https://aws.amazon.com/route53/pricing/)
- [Amazon EC2 on-demand pricing](https://aws.amazon.com/ec2/pricing/on-demand/)
- [AWS Pricing Calculator](https://calculator.aws/)
