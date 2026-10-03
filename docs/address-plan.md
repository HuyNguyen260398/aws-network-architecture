# Address plan

Every address range in the project, in one place. Planning these before the
first `terraform apply` is not bureaucracy: a subnet's range cannot be
changed after it is created, and two networks with overlapping ranges cannot
be connected by any mechanism.

## Networks

| Network | Range | Arrives in | Notes |
| --- | --- | --- | --- |
| **Supernet** | `10.0.0.0/8` | 09 | Contains every VPC. One route or rule covers all of them. |
| shop VPC | `10.10.0.0/16` | 01 | Production. |
| shared VPC | `10.20.0.0/16` | 09 | Tools used by every team. |
| dev VPC | `10.30.0.0/16` | 09 | Must not reach the shop. |
| partner VPC | `10.40.0.0/16` | 14 | Created by two of the challenges. |
| DR VPC | `10.110.0.0/16` | 13 | Second Region. Regions do not change the plan. |
| office | `192.168.0.0/16` | 12 | On-premises. Outside the supernet on purpose. |
| Docker bridge | `172.18.0.0/16` | 06 | Exists inside one host only. Never routed. |
| Kubernetes Services | `172.20.0.0/16` | 07 | Virtual. Never routed, but must not collide. |

Each VPC is a `/16`: 65,536 addresses, and the largest a VPC can be.

## Subnets in the shop VPC

`/24`s, numbered by tier with gaps between tiers so each can grow.

| Subnet | Range | Zone | Tier |
| --- | --- | --- | --- |
| `public-a` | `10.10.0.0/24` | A | Web, load balancer, NAT |
| `public-b` | `10.10.1.0/24` | B | |
| `app-a` | `10.10.10.0/24` | A | Payment service, ECS tasks, EKS nodes and pods |
| `app-b` | `10.10.11.0/24` | B | |
| `data-a` | `10.10.20.0/24` | A | Database |
| `data-b` | `10.10.21.0/24` | B | |
| `firewall-a` | `10.10.30.0/24` | A | Network Firewall endpoint (lab 08, opt-in) |
| `tgw-a` | `10.10.255.240/28` | A | Transit Gateway attachment (lab 10, opt-in) |

A `/24` has 256 addresses and **251 usable**: AWS reserves the network
address, `.1` (VPC router), `.2` (DNS resolver), `.3` (reserved) and the
broadcast address in every subnet.

The other VPCs each have one subnet, `public-a` at `x.x.0.0/24`, and a
`tgw-a` at `x.x.255.240/28` when the Transit Gateway is on.

## Ports

| Port | Used by | Reachable from |
| --- | --- | --- |
| 80 | frontend | The internet (lab 01–04), the load balancer (05+), the office (12) |
| 9090 | payment | The internet (lab 01 only), then the web tier; the load balancer (05); dev, through PrivateLink (11); the DR Region (13) |
| 3306 | database | The app tier only |
| 8080 | Docker published port (06); tools in shared and dev (09) | The internet; any VPC in the supernet |
| 443 | AWS service endpoints | The VPC |
| 53 | DNS (UDP and TCP) | The VPC resolver; Resolver endpoints (11) |
| 500, 4500 (UDP) | IKE and IPsec NAT traversal | The two AWS tunnel endpoints (12) |

## Rules the plan follows

1. **No overlaps, including with networks you do not own yet.** The office
   range and the Kubernetes Service range are chosen to stay clear of
   `10.0.0.0/8` entirely.
2. **A supernet.** Every VPC inside one range means one Transit Gateway route
   per VPC route table, and security group rules that already cover the next
   VPC.
3. **Gaps between tiers.** Adding a third Availability Zone adds `public-c`
   at `.2`, `app-c` at `.12`, `data-c` at `.22` and renumbers nothing.
4. **Small, dedicated subnets for infrastructure.** Firewall endpoints and
   gateway attachments get their own, so route tables and network ACLs can
   treat them separately from workloads.
