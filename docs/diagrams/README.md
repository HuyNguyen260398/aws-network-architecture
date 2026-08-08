# Diagrams

Every lab's architecture diagram lives in that lab's `README.md`, next to the
explanation it belongs with. This page collects the cross-cutting ones and
explains the conventions.

All diagrams in this repository are **Mermaid**, rendered inline by GitHub. No
image files, no external tooling, and a diff on a diagram is readable.

---

## Conventions

| Colour | Meaning |
| --- | --- |
| 🟢 Green (`#2d6a4f`) | Free resource, or the route that makes something work |
| 🟤 Brown (`#7f5539`) | Private or isolated — no path out |
| 🔵 Blue (`#1d3557`) | Gateway (internet gateway, Transit Gateway) |
| 🔴 Red (`#9d0208`) | **Billed by the hour** |
| 🔴 Dark red (`#6a040f`) | Billed by the hour, and expensively |

Solid arrows are traffic paths. Dotted arrows are relationships, or paths that
do **not** work.

---

## The whole repository

```mermaid
graph TB
    subgraph FOUND["Foundations — free or cents"]
        L01["01 · VPC fundamentals"]
        L02["02 · Public/private subnets"]
        L03["03 · VPC endpoints"]
    end

    subgraph CONN["Connectivity"]
        L04["04 · VPC peering"]
        L05["05 · Transit Gateway"]
        L06["06 · DNS and PrivateLink"]
        L09["09 · Multi-Region"]
    end

    subgraph HYB["Hybrid"]
        L07["07 · Site-to-Site VPN<br/>Direct Connect concepts"]
    end

    subgraph OPS["Operations"]
        L08["08 · Security and observability"]
        L10["10 · Troubleshooting"]
    end

    BOOT["bootstrap · S3 state backend"]

    BOOT --> FOUND
    L01 --> L02 --> L03
    L02 --> L04 --> L05
    L03 --> L06
    L05 --> L07
    L06 --> L07
    L04 --> L09
    L05 --> L09
    L02 --> L08 --> L10

    style L05 fill:#9d0208,color:#fff
    style L07 fill:#9d0208,color:#fff
    style L01 fill:#2d6a4f,color:#fff
    style BOOT fill:#1d3557,color:#fff
```

---

## Deciding how to connect two networks

```mermaid
graph TD
    Q1{"Do the two sides need<br/>full IP connectivity,<br/>or just one service?"}
    Q2{"How many VPCs?"}
    Q3{"Do the CIDRs overlap?"}
    Q4{"Is on-premises involved?"}

    PL["<b>PrivateLink</b><br/>~$8/mo per consumer<br/>no routes exchanged<br/>overlapping CIDRs fine<br/>unidirectional"]
    PEER["<b>VPC peering</b><br/>FREE<br/>not transitive<br/>n(n-1)/2 connections"]
    TGW["<b>Transit Gateway</b><br/>~$36/mo per attachment<br/>transitive<br/>route tables = segmentation"]
    READDR["<b>Re-address, or PrivateLink</b><br/>overlapping networks<br/>cannot be routed together"]
    VPN["<b>Site-to-Site VPN</b> ~$36/mo<br/>or <b>Direct Connect</b><br/>terminate on a TGW if<br/>more than one VPC needs it"]

    Q1 -->|"one service"| PL
    Q1 -->|"full connectivity"| Q3
    Q3 -->|"yes"| READDR
    Q3 -->|"no"| Q4
    Q4 -->|"yes"| VPN
    Q4 -->|"no"| Q2
    Q2 -->|"2, maybe 3"| PEER
    Q2 -->|"4 or more"| TGW

    style PL fill:#2d6a4f,color:#fff
    style PEER fill:#2d6a4f,color:#fff
    style TGW fill:#9d0208,color:#fff
    style VPN fill:#9d0208,color:#fff
    style READDR fill:#6a040f,color:#fff
```

The first question is the one people skip. A great many "we need to peer these
VPCs" requests are really "team X needs to call team Y's API", and PrivateLink
solves that without merging two address spaces forever.

---

## Giving a private subnet outbound access

```mermaid
graph TD
    Q1{"What does it<br/>need to reach?"}
    Q2{"How many<br/>AWS services?"}

    GW["<b>Gateway endpoint</b><br/><b>FREE</b><br/>S3 and DynamoDB only<br/>this VPC only"]
    IF["<b>Interface endpoints</b><br/>~$8/mo per ENI<br/>traffic stays on AWS<br/>reachable from on-prem"]
    NAT["<b>NAT gateway</b><br/>~$43/mo + $0.059/GB<br/>reaches everything"]
    EIGW["<b>Egress-only IGW</b><br/><b>FREE</b><br/>IPv6 outbound only"]
    NOTHING["<b>Nothing</b><br/>FREE<br/>genuinely isolated"]

    Q1 -->|"S3 or DynamoDB"| GW
    Q1 -->|"other AWS services"| Q2
    Q1 -->|"the actual internet"| NAT
    Q1 -->|"IPv6 outbound"| EIGW
    Q1 -->|"nothing outside the VPC"| NOTHING
    Q2 -->|"up to ~5"| IF
    Q2 -->|"more than ~5"| NAT

    style GW fill:#2d6a4f,color:#fff
    style EIGW fill:#2d6a4f,color:#fff
    style NOTHING fill:#2d6a4f,color:#fff
    style IF fill:#9d0208,color:#fff
    style NAT fill:#9d0208,color:#fff
```

Gateway endpoints are free and strictly better than routing S3 or DynamoDB
traffic through a NAT gateway. There is no configuration in which you should not
have them.

---

## Diagnosing a failed connection

```mermaid
graph TD
    S["Connection fails"]
    T{"How does it fail?"}
    TO["Times out after ~60s"]
    RF["Connection refused"]
    AD["AccessDenied, instant"]
    DNS["Cannot resolve host"]

    RA["<b>Reachability Analyzer</b><br/>$0.10 · names the component"]
    FL{"Flow logs:<br/>is there a record?"}
    ROUTE["<b>Routing</b><br/>route tables both sides<br/>peering · TGW · blackholes"]
    FILT["<b>Filtering</b><br/>security groups<br/>then NACLs in number order"]
    APP["<b>Application</b><br/>listening? OS firewall?"]
    POL["<b>Policy</b><br/>IAM · endpoint policy<br/>bucket policy"]
    RES["<b>DNS</b><br/>VPC attributes<br/>zone associations"]

    S --> T
    T -->|"timeout"| RA
    T -->|"refused"| APP
    T -->|"denied"| POL
    T -->|"no such host"| RES
    RA -->|"still unclear"| FL
    FL -->|"nothing"| ROUTE
    FL -->|"REJECT"| FILT
    FL -->|"ACCEPT both ways"| APP

    style RA fill:#2d6a4f,color:#fff
    style ROUTE fill:#7f5539,color:#fff
    style FILT fill:#9d0208,color:#fff
```

**A timeout means nothing answered. A refusal means something did.** That
distinction, made before reading any configuration, saves more time than any
tool.

Full method in [`../troubleshooting.md`](../troubleshooting.md).

---

## The five expensive resources

```mermaid
graph LR
    NFW["<b>Network Firewall</b><br/>$0.395/hr<br/><b>$288/mo</b>"]
    RES["<b>Resolver endpoint</b><br/>$0.25/hr · 2 ENIs mandatory<br/><b>$180/mo</b>"]
    NAT["<b>NAT gateway</b><br/>$0.059/hr<br/><b>$43/mo</b>"]
    TGW["<b>TGW attachment</b><br/>$0.05/hr each<br/><b>$36/mo</b>"]
    VPN["<b>VPN connection</b><br/>$0.05/hr<br/><b>$36/mo</b>"]

    NFW --- RES --- NAT --- TGW --- VPN

    style NFW fill:#6a040f,color:#fff
    style RES fill:#6a040f,color:#fff
    style NAT fill:#9d0208,color:#fff
    style TGW fill:#9d0208,color:#fff
    style VPN fill:#9d0208,color:#fff
```

All five are off by default and need both a feature flag and
`acknowledge_costs = true`. Prices are ap-southeast-1; see
[`../cost-guide.md`](../cost-guide.md).

---

## Adding a diagram

Put it in the lab README next to the explanation. Mermaid, styled with the
palette above, and it must show the **mechanism** — the route, the ENI, the rule
— rather than boxes labelled with service names. A diagram that does not say
anything the prose does not is not worth the lines.

Check it renders by previewing the Markdown; GitHub renders ```` ```mermaid ````
fences natively.
