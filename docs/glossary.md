# Glossary

Terms as they are used in this repository, with the detail that actually
matters rather than the one-line definition.

Entries marked 💰 cost money by the hour.

---

## A

**Amazon-provided DNS resolver** — Answers DNS queries inside a VPC, at the VPC's
base address plus two (`10.0.0.2` for `10.0.0.0/16`) and also at the link-local
address `169.254.169.253`. Requires `enableDnsSupport` on the VPC. Turn it off
and nothing in the VPC resolves anything.

**Appliance mode** — A setting on a Transit Gateway VPC attachment that keeps
both directions of a flow on the same Availability Zone. Required for stateful
inspection appliances; without it the gateway may route the two directions
through different zones and a firewall that sees half a conversation drops it.
Not supported on peering attachments.

**Association (Transit Gateway)** — Which **one** route table an attachment
consults when **sending**. Compare *propagation*. Getting these two confused is
the most common Transit Gateway mistake, and it produces one-way connectivity
rather than an error.

**Availability Zone (AZ)** — One or more discrete data centres within a Region,
with independent power, cooling and networking. A subnet lives in exactly one AZ
and cannot span zones. **AZ names are per-account**: your `ap-southeast-1a` is
physically a different zone from someone else's. Use *AZ IDs* (`apse1-az1`) when
that matters.

---

## B

**BGP (Border Gateway Protocol)** — How routes are exchanged dynamically over a
VPN or Direct Connect. The alternative is static routing, where you list the
prefixes by hand. BGP gives sub-minute failover and both tunnels active with
ECMP; static gives simplicity and tens-of-seconds failover.

**Blackhole route** — A route whose target no longer exists, or one explicitly
created to discard traffic. It is **not an error**, appears as a healthy entry
in the route table, and silently drops everything matching it. A genuinely hard
fault to find unless you know to look for `State: blackhole`.

---

## C

**CIDR (Classless Inter-Domain Routing)** — `10.0.0.0/16` notation. The number
after the slash is how many leading bits are the network portion. A `/16` has
65,536 addresses, a `/24` has 256, a `/28` has 16. **AWS reserves 5 addresses in
every subnet**, so a `/24` gives you 251 usable.

**CloudFront** — AWS's CDN. Layer 7, caches content at edge locations. Compare
*Global Accelerator*, which does not cache and works at layer 4.

**CloudTrail** — Records AWS API calls. Every VPC, route table, security group
and NACL change is an EC2 API call and appears here. The only place that records
**who** and **when**.

**Customer gateway (CGW)** — A record in AWS of your on-premises VPN device: its
public IP address and its BGP ASN. Creating one does nothing and costs nothing;
it is referenced by a VPN connection.

---

## D

**Dead peer detection (DPD)** — IKE keepalives. Without it, a tunnel that has
silently failed still looks up locally and traffic disappears into it.

**Direct Connect** — A dedicated physical circuit between your network and AWS.
Consistent latency, high bandwidth, and **no encryption by default** — it is a
private circuit, not an encrypted one. Regulated workloads commonly run an IPsec
VPN over it. Requires a physical cross-connect at a colocation facility, ordered
through AWS or a partner, with weeks of lead time. 💰

**Direct Connect gateway (DX gateway)** — Lets one Direct Connect connection
reach VPCs in multiple Regions and multiple accounts. **Free** with no virtual
interfaces attached, which is why [lab 07](../labs/07-hybrid-networking/README.md)
can create a real one.

---

## E

**ECMP (Equal-Cost Multi-Path)** — Spreading traffic across several equal-cost
paths. On a Transit Gateway with BGP it lets multiple VPN tunnels carry traffic
simultaneously instead of one being standby.

**Egress-only internet gateway (EIGW)** — The IPv6 equivalent of a NAT gateway:
outbound connections succeed, unsolicited inbound ones are dropped. **Completely
free.** It performs no address translation — there is no IPv6 NAT on AWS, and
the instance's own global address is on the wire.

**Elastic IP (EIP)** — A static public IPv4 address you own. **Charged when
idle** (~USD 0.005/hour) precisely because it is not attached to anything. The
classic leftover after a partial `terraform destroy`.

**ENI (Elastic Network Interface)** — A virtual network card. Has a private IP,
security groups, and optionally a public IP. Interface endpoints, NAT gateways,
Transit Gateway attachments and Resolver endpoints are all ENIs under the
surface, which is why several of them are billed per ENI-hour.

**Endpoint policy** — A resource policy on a VPC endpoint restricting what can
be reached **through** it. It **grants nothing** — the caller's IAM policy must
also allow the call. A policy allowing only bucket X denies bucket Y **by
omission**, with no `Deny` statement to grep for.

**Ephemeral port** — The source port a client's kernel picks for an outbound
connection; the reply is addressed to it. Linux uses 32768–60999, Windows
49152–65535, ELB 1024–65535. Because network ACLs are stateless, they need an
inbound allow for this range or every outbound connection hangs.

---

## F

**Flow logs** — Metadata about IP traffic: source, destination, ports, bytes,
and `ACCEPT` or `REJECT`. **Not packet contents** — that is traffic mirroring.
The `action` field distinguishes "filtered" from "never arrived", which is the
single most useful thing in network troubleshooting.

---

## G

**Gateway endpoint** — A VPC endpoint for **S3 or DynamoDB only**. It is a
**route**, not a device: AWS adds a managed prefix list destination to the route
tables you nominate. No ENI, no security group, no address, and **free**.
Invisible from outside the VPC, so it cannot be used from on-premises or from a
peered VPC.

**Global Accelerator** — Two static anycast IP addresses that route traffic onto
the AWS backbone at the nearest edge location. Layer 4, works with TCP and UDP,
and **does not cache**. USD 0.025/hour fixed. Compare *CloudFront*. 💰

---

## I

**IGW (Internet gateway)** — Connects a VPC to the internet. Free to create and
keep; you pay for data out. Performs 1:1 NAT between an instance's private
address and its public one — an instance with no public IP cannot use it,
whatever the route table says.

**IKE (Internet Key Exchange)** — The protocol that negotiates an IPsec tunnel.
Phase 1 establishes the control channel (ISAKMP SA); phase 2 establishes the
data channel (IPsec SA). Phase 1 must succeed before phase 2 is attempted, which
is why the log order matters when debugging.

**IMDSv2** — The token-required version of the instance metadata service. The
unauthenticated `GET` of IMDSv1 is what turns a server-side request forgery bug
into stolen instance credentials. Every instance in this repository sets
`http_tokens = "required"`.

**Interface endpoint** — A VPC endpoint that is an **ENI in your subnet** with a
private address from your CIDR, fronted by PrivateLink. Has a security group,
billed per ENI-hour, and because it is an ordinary private address it **is**
reachable from on-premises and from peered VPCs. 💰

---

## L

**Local route** — The `10.0.0.0/16 → local` entry present in every route table.
**Cannot be removed or overridden.** It is why every subnet in a VPC can reach
every other by default, and why two VPCs with overlapping CIDRs can never be
peered.

**Longest-prefix match** — How routes are selected. `10.0.1.0/24` beats
`10.0.0.0/16` beats `0.0.0.0/0` for the address `10.0.1.5`.

---

## M

**Managed prefix list** — A named, AWS-maintained set of CIDR blocks — for
example every S3 IP range in a Region. Referenced in route tables (this is how
gateway endpoints work) and in security group rules, so you never hardcode
ranges AWS changes.

**MTU (Maximum Transmission Unit)** — Largest packet that can traverse a path.
9001 within a VPC, 1500 through an internet gateway, ~1436 over VPN, 8500
through a Transit Gateway, 1500 for inter-Region peering. Path MTU discovery
needs **ICMP type 3 code 4**; block all ICMP and large transfers hang
mysteriously.

---

## N

**NAT gateway** — Managed network address translation for private subnets:
outbound IPv4 works, inbound does not. Must live in a **public** subnet — it
needs its own route to an internet gateway. ~USD 0.059/hour plus ~USD 0.059/GB.
**The most common source of surprise charges in a learning account.** 💰

**Network ACL (NACL)** — A **stateless** filter on a **subnet**. Supports
**deny**, evaluated in **rule-number order**, and **evaluation stops at the first
match**. Read one top to bottom like a routing table, never as a set of rules.
Rule 32767 (`deny all`) is added automatically and cannot be removed.

**Network Firewall** — AWS's managed stateful firewall with Suricata-compatible
rules. ~USD 0.395 per endpoint-hour plus ~USD 0.065/GB. **The most expensive
resource in this repository**, at roughly USD 288/month per endpoint. 💰

---

## P

**Peering (VPC)** — A one-to-one connection between two VPCs. Free to create.
**Not transitive**: a packet cannot enter a VPC over one peering connection and
leave over another. Requires non-overlapping CIDRs, and requires routes on
**both** sides.

**Prefix list** — See *managed prefix list*.

**PrivateLink** — Consuming a service in another VPC or account **without
joining the networks**. No routes are exchanged, so the two VPCs may have
identical CIDRs. Unidirectional by construction: the consumer reaches the
service, never the reverse. Implemented as an endpoint service (provider side)
and an interface endpoint (consumer side). 💰

**Private hosted zone** — A Route 53 DNS zone that resolves only from the VPCs
it is associated with. **Authoritative** inside them: Route 53 does not fall
through to the public answer for a name it cannot find, so a private zone for
`example.com` containing only an apex record makes `www.example.com` `NXDOMAIN`
inside the VPC.

**Propagation (Transit Gateway)** — Which route tables **learn** an attachment's
CIDR. Any number per attachment, and completely independent of *association*.

---

## R

**Reachability Analyzer** — Static analysis of a network path. Sends **no
packet**; evaluates route tables, security groups, NACLs, gateways and
endpoints, and names the blocking component when a path is unreachable. Paths
are free; each analysis costs USD 0.10. Knows nothing about liveness, OS
firewalls, DNS, or blackhole routes.

**Region** — A geographic area containing multiple Availability Zones. The
hardest boundary in AWS: nothing crosses it implicitly.

**Resolver endpoint (Route 53)** — Inbound lets external DNS servers resolve
your private zones; outbound forwards queries for specific domains to servers
you nominate. **USD 0.125 per ENI-hour with a minimum of two ENIs**, so
USD 0.25/hour, USD 180/month. There is no cheaper configuration. 💰

**Resolver rule** — Which domain an outbound Resolver endpoint forwards, and to
where. A rule does nothing until it is **associated** with a VPC.

**Route propagation** — Automatically installing routes learned over a VPN or
Direct Connect into a VPC route table. Look for `Origin:
EnableVgwRoutePropagation` in `describe-route-tables`.

**Route table** — Determines where packets from a subnet go. **This, and nothing
else, is what makes a subnet public or private.**

---

## S

**Security group** — A **stateful** filter on an **ENI**. Allow-only; no deny
rules exist. All rules are evaluated and any allow permits. Can reference
another security group by ID, which names an identity rather than an address —
the rule keeps working as instances come and go.

**Session Manager** — Shell access to an instance through the SSM agent's
**outbound** connection. No inbound rules, no key pair, no bastion. Needs a
network path to the Systems Manager endpoints: a public IP in a public subnet, a
NAT gateway, or the three interface endpoints `ssm`, `ssmmessages`,
`ec2messages` — **all three**.

**Shield Standard / Advanced** — Standard is free, automatic and always on for
every AWS customer. Advanced is **USD 3,000/month** with a one-year commitment.
💰 (Advanced)

**Source/destination check** — EC2 drops packets whose source or destination is
not the instance itself, unless this is disabled. **Must be off for any instance
that forwards traffic** — a NAT instance, a software VPN endpoint, a router. A
working tunnel that carries no traffic is usually this.

**Split-horizon DNS** — The same name resolving differently inside and outside a
VPC, using a private hosted zone for a domain that also exists publicly.

**Static route** — A route you write, as opposed to one learned by BGP or
propagation. On a Transit Gateway a static route **always beats** a propagated
one for the same prefix, which is the answer to a surprising number of "but BGP
is advertising it" problems.

---

## T

**Traffic mirroring** — Copies **actual packets** from an ENI to a monitoring
appliance, where flow logs copy only metadata. Nitro instances only; consumes
the source instance's bandwidth.

**Transit Gateway (TGW)** — A regional router connecting VPCs, VPNs and Direct
Connect. The gateway itself is free; each **attachment** is ~USD 0.05/hour. Its
route tables are where network segmentation lives. 💰 (attachments)

**Transitive routing** — Traffic passing *through* an intermediate network to a
third. VPC peering does **not** support it; a Transit Gateway does. The absence
of transitive routing in peering is why Transit Gateway exists.

---

## V

**Virtual interface (VIF)** — A BGP session on a Direct Connect connection.
Private (reaches VPCs), public (reaches AWS public endpoints), or transit
(reaches a Transit Gateway via a DX gateway).

**Virtual private gateway (VGW)** — The AWS-side VPN endpoint for **exactly one
VPC**. Free, and cannot be shared — which is why designs with several VPCs move
to a Transit Gateway VPN attachment.

**VPC (Virtual Private Cloud)** — A logically isolated network in one Region.
Its CIDR **cannot be changed** after creation, only extended with secondary
blocks.

**VPC endpoint service** — The provider side of PrivateLink. Fronted by a
Network Load Balancer, published to specific principals, and optionally
requiring explicit acceptance of each consumer connection.

---

## Abbreviations

| | |
| --- | --- |
| ACL | Access Control List |
| ASN | Autonomous System Number |
| AZ | Availability Zone |
| BGP | Border Gateway Protocol |
| CGW | Customer Gateway |
| CIDR | Classless Inter-Domain Routing |
| DPD | Dead Peer Detection |
| DX | Direct Connect |
| ECMP | Equal-Cost Multi-Path |
| EIGW | Egress-only Internet Gateway |
| EIP | Elastic IP |
| ENI | Elastic Network Interface |
| GWLB | Gateway Load Balancer |
| IGW | Internet Gateway |
| IKE | Internet Key Exchange |
| IMDS | Instance Metadata Service |
| LOA-CFA | Letter of Authorisation and Connecting Facility Assignment |
| MTU | Maximum Transmission Unit |
| NACL | Network Access Control List |
| NAT | Network Address Translation |
| NLB | Network Load Balancer |
| PHZ | Private Hosted Zone |
| PMTUD | Path MTU Discovery |
| PSK | Pre-Shared Key |
| RAM | Resource Access Manager |
| SA | Security Association |
| SG | Security Group |
| SSM | AWS Systems Manager |
| TGW | Transit Gateway |
| VGW | Virtual Private Gateway |
| VIF | Virtual Interface |
| VPCE | VPC Endpoint |
