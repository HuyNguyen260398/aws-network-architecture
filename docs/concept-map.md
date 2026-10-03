# Concept map

Where each idea from
[Every Networking Concept Explained In 20 Minutes](https://www.youtube.com/watch?v=xj_GjnD4uyI)
(TechWorld with Nana) is built in this repository. The video's concept list,
by chapter, is in
[`networking-concepts-by-video-section.md`](../networking-concepts-by-video-section.md).

The video tells one story — a single server growing into cloud
infrastructure, containers and Kubernetes — and labs 01–07 follow it in the
same order, with the same example application.

## Section by section

### 2 · Single server: IP and DNS — [lab 01](../labs/01-single-server/README.md)

| Concept | Where |
| --- | --- |
| IP addresses | The server's private address; `server_private_ip` |
| Public IP addresses | The server's public address and the internet gateway's 1:1 translation |
| Domain names, DNS and name resolution | `dns.tf`: an A record, or the AWS-assigned name; `dig` exercises |
| Client–server communication | Traffic flow, step by step |

Private DNS — names that exist only inside the network — is
[lab 11](../labs/11-dns-and-privatelink/README.md).

### 3 · Multiple apps: ports — [lab 01](../labs/01-single-server/README.md)

| Concept | Where |
| --- | --- |
| Ports and port numbers | Frontend on 80 and payment on 9090, one address |
| Listening ports | `ss -ltnp`; timeout versus refusal |
| Multiple applications sharing one IP | The whole lab; exercise 1 adds a third |
| Standard and custom ports | 80, 9090, then 3306 in lab 02 — the video's own numbers |

### 4 · Security and segmentation — [lab 02](../labs/02-network-segmentation/README.md), [lab 08](../labs/08-security-and-observability/README.md)

| Concept | Where |
| --- | --- |
| Network segmentation | Web, app and data tiers in separate subnets (02) |
| Subnets and IP address ranges | `network.tf`; [`address-plan.md`](address-plan.md) |
| Routing and routers | The `local` route between subnets (02); route tables throughout |
| Firewalls | Security groups, from lab 01 |
| Host firewalls | nftables on the internet-facing host (01, 02; exercise in 03) |
| Network firewalls | Network ACLs on the data tier (02); AWS Network Firewall (08) |
| IP- and port-based filtering | Every security group and ACL rule |
| Layered security and secure zones | Lab 02's three controls on one path |

### 5 · NAT — [lab 03](../labs/03-nat-and-outbound/README.md)

| Concept | Where |
| --- | --- |
| Private IP addresses and private subnets | App and data tiers (02) |
| Public versus private addressing | Why a private host cannot be replied to |
| NAT | The NAT gateway |
| Source-address translation | `curl checkip` from two hosts returns one address |
| Return-traffic tracking | Traffic flow, step 4; unsolicited inbound is dropped |
| Outbound internet access | Session Manager registration, package installs |

### 6 · Cloud networking — labs [01](../labs/01-single-server/README.md)–[04](../labs/04-private-aws-access/README.md)

| Concept | Where |
| --- | --- |
| VPC | 01 |
| Public and private subnets | 01, 02 |
| Internet gateway | 01 |
| Route tables | 01, 02 — "the route that makes a subnet public" |
| NAT gateway | 03 |
| Security groups | 01, chained by reference in 02 |
| Managed networking | VPC endpoints (04): private access to AWS's own services |

### 7 · Container networking — [lab 06](../labs/06-container-networking/README.md)

| Concept | Where |
| --- | --- |
| Docker bridge networks | The `shop-net` bridge on the Docker host |
| Container-name communication | The frontend container calls `http://payment:9090/` |
| Private container networking and internal ports | `172.18.x.x` addresses; container port 80 |
| Port mapping / port binding | Host 8080 → container 80 |
| Traffic forwarding and address/port translation | The DNAT rule, read with `nft` |
| Overlay networks | Explained; ECS `awsvpc` mode shown as the alternative |
| Service replicas | Two ECS tasks behind one Cloud Map name |

### 8 · Kubernetes networking — [lab 07](../labs/07-kubernetes-networking/README.md), [lab 05](../labs/05-load-balancing/README.md)

| Concept | Where |
| --- | --- |
| Pod IP addresses | VPC addresses from the app subnets, via the VPC CNI |
| Shared pod addressing | Exercise 2: two containers, one IP |
| Ephemeral pods and changing IPs | Exercise 1: delete a pod, watch the address change |
| Service discovery | Cluster DNS; Cloud Map in lab 06 |
| Kubernetes Services | `payment` and `frontend` Services; ClusterIP |
| Forwarding to healthy pods | EndpointSlices; readiness probes |
| Ingress | The `shop` Ingress, implemented by a load balancer |
| Domain- and URL-path-based routing | Ingress rules (07); the same rules by hand on an ALB (05) |

### 9 · Recap — five fundamentals

| Fundamental | Labs |
| --- | --- |
| IP addresses and DNS | 01, 11 |
| Ports | 01, 02 |
| Segmentation, subnets and routing | 02, 09, 10 |
| Firewalls and access control | 01, 02, 08 |
| NAT | 03 |

## Beyond the video

Labs 08–14 cover what running a network in AWS needs that a twenty-minute
overview cannot.

| Lab | Adds |
| --- | --- |
| [04](../labs/04-private-aws-access/README.md) | VPC endpoints, endpoint policies |
| [08](../labs/08-security-and-observability/README.md) | Flow logs, Reachability Analyzer, CloudTrail, inspection routing |
| [09](../labs/09-vpc-peering/README.md) | Multiple VPCs, peering, non-transitivity |
| [10](../labs/10-transit-gateway/README.md) | Transit Gateway, segmentation by route table |
| [11](../labs/11-dns-and-privatelink/README.md) | Private hosted zones, split horizon, PrivateLink, Resolver endpoints |
| [12](../labs/12-hybrid-networking/README.md) | Site-to-Site VPN, route propagation, Direct Connect |
| [13](../labs/13-multi-region/README.md) | Inter-Region peering, Transit Gateway peering, DNS failover |
| [14](../labs/14-troubleshooting-challenges/README.md) | A troubleshooting method, practised on six faults |

## What is explained but not built

| Concept | Why | Where it is explained |
| --- | --- | --- |
| Overlay networks | AWS's container services use VPC-native addressing instead | Lab 06 |
| HTTPS on the load balancer | Needs a domain the labs cannot assume | Lab 05 |
| Direct Connect circuits | Need a physical cross-connect | Lab 12 |
| Global Accelerator, CloudFront | Billed monthly; out of proportion for a lab | Lab 13 |
| Kubernetes NetworkPolicy | Application-level policy on top of this network | Lab 07 mapping table |
