# Hints

Read these **only when you are stuck**, and only the hint for the challenge you
are working on. Each challenge has three hints in increasing order of
specificity — take the first one and go back to the console before reading the
second.

Answers are in [SOLUTIONS.md](SOLUTIONS.md). Try not to.

---

## A method that works for all of them

Before any specific hint, this ordering saves time on every network fault:

1. **Can the packet get there?** Route tables, on **both** sides.
2. **Is something dropping it?** Security groups, then network ACLs.
3. **Is the name resolving to the right thing?** DNS.
4. **Is the destination actually listening?** The application.

Flow logs tell you which of steps 1 and 2 you are in: a `REJECT` record means it
arrived and was filtered; **no record at all** means it never arrived.

Reachability Analyzer (USD 0.10) collapses steps 1 and 2 into a single answer
that names the component. When you have spent more than ten minutes, it is
cheap.

---

## `missing-route`

**Symptom:** the client cannot reach the peer VPC's instance. The peering
connection reports `active`.

<details>
<summary>Hint 1</summary>

`active` describes the peering connection's own state. It says nothing about
whether any traffic can use it. What has to exist, in addition to the
connection, before a packet moves?
</details>

<details>
<summary>Hint 2</summary>

You checked one route table. There are two VPCs involved.

Think about what happens to the *reply* to your ICMP echo request.
</details>

<details>
<summary>Hint 3</summary>

```bash
aws ec2 describe-route-tables --region <region> \
  --filters Name=tag:Lab,Values=10-troubleshooting-challenges \
  --query 'RouteTables[].{Name:Tags[?Key==`Name`]|[0].Value,Routes:Routes[].DestinationCidrBlock}'
```

Compare the two lists. One VPC knows about the other; the other does not know
about the first.
</details>

---

## `overlapping-cidr`

**Symptom:** you have been asked to peer two VPCs and cannot.

<details>
<summary>Hint 1</summary>

Look at the two VPCs' CIDR blocks before looking at anything else.
</details>

<details>
<summary>Hint 2</summary>

Suppose the peering connection existed. An instance at `10.100.0.5` sends a
packet to `10.100.0.9`. Which route matches — the `local` route, or the peering
route?

Can the `local` route be removed or overridden?
</details>

<details>
<summary>Hint 3</summary>

Try creating the peering connection and read the error:

```bash
aws ec2 create-vpc-peering-connection --region <region> \
  --vpc-id <base-vpc-id> --peer-vpc-id <overlap-vpc-id>
```

Then ask a different question: does the requirement actually need *network*
connectivity, or does one side need to call a *service* on the other? Lab 06
solves the second version.
</details>

---

## `security-group`

**Symptom:** `curl` from the client to the server on port 8080 times out. The
network ACLs allow everything.

<details>
<summary>Hint 1</summary>

The server's security group does have a rule for port 8080. Read it more
carefully than "there is a rule for 8080".
</details>

<details>
<summary>Hint 2</summary>

The rule's source is a security group reference, not a CIDR. Which group?

```bash
terraform output -json investigation_starters | jq -r .security_group_ids
```
</details>

<details>
<summary>Hint 3</summary>

```bash
terraform output -json investigation_starters | jq -r .all_security_group_rules | bash
```

Compare the `SourceSG` column against the two group IDs from the previous hint.
The rule permits traffic from a group the client is not in.
</details>

---

## `nacl-ephemeral`

**Symptom:** an outbound connection from the server hangs. Every outbound rule
you can find allows it.

<details>
<summary>Hint 1</summary>

Security groups are stateful. Network ACLs are not. What does "not stateful"
mean for the *reply* to an outbound connection?
</details>

<details>
<summary>Hint 2</summary>

When a client opens a TCP connection, the kernel picks a source port. The
server's reply is addressed **to that port**. Which port range is it drawn from,
and does any inbound ACL rule cover it?
</details>

<details>
<summary>Hint 3</summary>

```bash
terraform output -json investigation_starters | jq -r .network_acls | bash
```

Look at the inbound entries. There is an allow for the VPC CIDR and the
implicit `deny all` at 32767. Replies come from outside the VPC CIDR, addressed
to a port in 1024–65535. Nothing allows them.
</details>

---

## `broken-dns`

**Symptom:** a private hosted zone exists, contains a correct A record, is
associated with the VPC, and resolving the name returns `NXDOMAIN`.

<details>
<summary>Hint 1</summary>

The zone is fine. The record is fine. The association is fine. So the problem is
not in Route 53 at all — it is in whatever is supposed to *ask* Route 53.
</details>

<details>
<summary>Hint 2</summary>

What answers a DNS query inside a VPC? At what address? Is that thing switched
on?
</details>

<details>
<summary>Hint 3</summary>

```bash
aws ec2 describe-vpc-attribute --region <region> --vpc-id <dns-vpc-id> --attribute enableDnsSupport
aws ec2 describe-vpc-attribute --region <region> --vpc-id <dns-vpc-id> --attribute enableDnsHostnames
```

Also worth knowing: the same two attributes are what interface VPC endpoint
private DNS depends on, so this fault presents in several disguises.
</details>

---

## `endpoint-policy`

**Symptom:** reading an object from the lab bucket over the S3 gateway endpoint
is denied. The instance role has `AmazonS3ReadOnlyAccess`.

<details>
<summary>Hint 1</summary>

Two policies must both allow an S3 request that arrives through an endpoint. You
have checked one of them.
</details>

<details>
<summary>Hint 2</summary>

An endpoint policy grants nothing — it *restricts* what can be reached through
the endpoint. A policy that allows only bucket X implicitly denies bucket Y,
with no `Deny` statement anywhere to grep for.
</details>

<details>
<summary>Hint 3</summary>

```bash
terraform output -json investigation_starters | jq -r .vpc_endpoints | bash
```

Read the `Policy` field and compare the bucket ARNs it names against
`terraform output -raw s3_bucket_name`.
</details>

---

## `missing-association`

**Symptom:** an S3 gateway endpoint exists and reports `available`. S3 access
from the private subnet still times out.

<details>
<summary>Hint 1</summary>

A gateway endpoint is not a device with an address. What kind of object does it
actually add to your VPC, and where does that object live?
</details>

<details>
<summary>Hint 2</summary>

The endpoint *is* associated with a route table. Is it associated with the route
table belonging to the subnet the traffic comes from?
</details>

<details>
<summary>Hint 3</summary>

```bash
terraform output -json investigation_starters | jq -r .vpc_endpoints | bash
terraform output -json investigation_starters | jq -r .all_route_tables | bash
```

Find which route table the *private* subnet is associated with, then check
whether the endpoint's `RouteTableIds` contains it. Look for the prefix-list
route: it is present in one table and absent from the other.
</details>

---

## `asymmetric-routing`

**Symptom:** two private subnets that look identical. One can reach the peer
VPC; the other cannot.

<details>
<summary>Hint 1</summary>

"Identical" is a claim about the subnets. Route tables are a separate resource.
How many private route tables does this VPC have, and why?
</details>

<details>
<summary>Hint 2</summary>

`modules/vpc` creates one private route table **per Availability Zone**. The two
subnets are in different zones.
</details>

<details>
<summary>Hint 3</summary>

```bash
aws ec2 describe-route-tables --region <region> \
  --filters Name=vpc-id,Values=<base-vpc-id> \
  --query 'RouteTables[].{Id:RouteTableId,Name:Tags[?Key==`Name`]|[0].Value,Subnets:Associations[].SubnetId,Peer:Routes[?VpcPeeringConnectionId!=null].DestinationCidrBlock}'
```

One table has the peering route. The other does not. This is what per-AZ route
tables cost you in exchange for the per-AZ NAT and inspection routing they make
possible: two places to keep in step, and no warning when they diverge.
</details>

---

## `flow-log-rejects`

**Symptom:** traffic is being dropped. Flow logs are on. Find the layer.

<details>
<summary>Hint 1</summary>

```bash
terraform output -raw flow_log_tail_command | bash
```

Run that in one window, generate the traffic in another, and wait about a
minute for the aggregation interval to elapse.
</details>

<details>
<summary>Hint 2</summary>

You are looking for the `action` field. Three outcomes, three different
conclusions:

| What you see | What it means |
| --- | --- |
| `REJECT` | A security group or NACL dropped it. **It arrived.** |
| `ACCEPT` out, nothing back | A stateless NACL is blocking the reply |
| Nothing at all | Routing. The packet never reached an interface. |
</details>

<details>
<summary>Hint 3</summary>

You have a `REJECT`, so it arrived and was filtered. Now narrow to which
filter. The security group allows this traffic — check it and confirm. That
leaves the network ACL.

Read its entries **in rule-number order**, and remember that evaluation stops at
the first match.
</details>
