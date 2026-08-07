# Solutions

Spoilers. Work the challenge and read [HINTS.md](HINTS.md) first — the value is
in the diagnosis, not the answer.

Each entry gives the fault, how to confirm it, how to fix it, and what the same
mistake looks like in production.

---

## `missing-route`

**Fault.** The peering connection is `active` and only the **base** VPC has a
route to the peer. `aws_route.peer_to_base` is not created for this challenge.

**Confirm**

```bash
aws ec2 describe-route-tables --region <region> \
  --filters Name=tag:Lab,Values=10-troubleshooting-challenges \
  --query 'RouteTables[].{Name:Tags[?Key==`Name`]|[0].Value,Routes:Routes[].DestinationCidrBlock}' \
  --output json
```

The base VPC's table lists `10.101.0.0/16`. The peer VPC's table does not list
`10.100.0.0/16`.

**Fix** — add the return route. In `main.tf`, change
`aws_route.peer_to_base`'s count so it is created:

```hcl
resource "aws_route" "peer_to_base" {
  count = local.need_peer_vpc ? 1 : 0     # was: local.c.asymmetric_routing ? 1 : 0
  ...
}
```

Or, to prove it before editing Terraform:

```bash
aws ec2 create-route --region <region> \
  --route-table-id <peer-rtb-id> \
  --destination-cidr-block 10.100.0.0/16 \
  --vpc-peering-connection-id <pcx-id>
```

The ping starts working immediately. (Run `terraform apply` afterwards to
reconcile state, or `terraform plan` will want to remove it.)

**Why it is confusing.** The echo request arrives at the peer instance
perfectly. The peer instance generates a reply. The reply has nowhere to go, so
it is dropped by the peer VPC's router. From the client the symptom is 100%
packet loss, identical to "the destination is down" or "a firewall blocks it".

**In production.** Two teams each own one VPC. One team adds their route and
tests; the other has not deployed yet. Or the peering was set up by one team who
had no permission to modify the other's route tables. Always check **both**
sides — this is the single most common VPC peering fault.

---

## `overlapping-cidr`

**Fault.** Two VPCs both use `10.100.0.0/16`. They cannot be peered, and no
configuration change makes them peerable.

**Confirm**

```bash
aws ec2 create-vpc-peering-connection --region <region> \
  --vpc-id <base-vpc-id> --peer-vpc-id <overlap-vpc-id>
```

```
An error occurred (InvalidVpcPeeringConnection.OverlappingCidrBlocks) ...
```

**Why it is impossible, not merely disallowed.** Suppose AWS permitted it. An
instance at `10.100.0.5` sends a packet to `10.100.0.9`. The route table
contains `10.100.0.0/16 → local`, which cannot be removed, cannot be overridden,
and matches. The packet is delivered locally. There is no way to express "this
`10.100.x.x` but not that one", because a route table matches on destination
prefix and nothing else.

The same applies to Transit Gateway (a route table cannot hold two entries for
the same prefix pointing at different attachments) and to Site-to-Site VPN.

**The four real options**

1. **Re-address one VPC.** Correct, and it means rebuilding every subnet and
   re-launching everything in it. Weeks, in a real environment.
2. **A secondary CIDR on one VPC** and move the workloads into it. Only helps if
   the *workloads*, not the whole VPC, need to be reachable.
3. **PrivateLink.** No routes are exchanged, so the address collision is
   irrelevant. Works today. Unidirectional and per-service, which is often
   exactly the requirement. See [lab 06](../06-dns-and-privatelink/README.md).
4. **A proxy or NAT instance in a third, non-overlapping VPC.** Possible, ugly,
   and it hides the real addresses from every log and every audit.

**In production.** Two companies merge and both used `10.0.0.0/16` because it is
the default in every tutorial. This is why the addressing decision in
[lab 01](../01-vpc-fundamentals/README.md) matters more than any other single
choice in a VPC.

---

## `security-group`

**Fault.** The server's ingress rule for TCP 8080 references the **server's own**
security group instead of the client's.

**Confirm**

```bash
terraform output -json investigation_starters | jq -r .security_group_ids
terraform output -json investigation_starters | jq -r .all_security_group_rules | bash
```

The `SourceSG` column shows the server's group ID, not the client's.

**Fix** — in `main.tf`:

```hcl
resource "aws_vpc_security_group_ingress_rule" "server_wrong_source" {
  referenced_security_group_id = aws_security_group.client.id   # was: .server.id
}
```

**Why it is confusing.** In the console the rule reads "Custom TCP, 8080,
sg-0abc123" and looks entirely purposeful. The description says "Service port
from the application tier", which is plausible. Nothing highlights that the
referenced group is the same one the rule is attached to.

A self-referencing security group rule is a *legitimate and common* pattern —
it is how you let cluster members talk to each other. That is precisely what
makes this hard to spot: the shape is right, the identity is wrong.

**In production.** Copy-paste between two similar rules. Or a group was renamed
and someone picked the wrong one from a dropdown of near-identical names. It
survives review because reviewers check that a rule exists for the port, not
which group ID it names.

---

## `nacl-ephemeral`

**Fault.** The network ACL on the private subnet allows inbound traffic from the
VPC CIDR and nothing else. Replies to outbound connections arrive from outside
the VPC, addressed to an ephemeral port, and match no inbound rule.

**Confirm**

```bash
terraform output -json investigation_starters | jq -r .network_acls | bash
```

Inbound entries: rule 100 allows `10.100.0.0/16`; rule 32767 denies everything.
There is no allow covering 1024–65535 from `0.0.0.0/0`.

**Fix**

```hcl
resource "aws_network_acl_rule" "private_in_ephemeral" {
  network_acl_id = aws_network_acl.private[0].id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}
```

**Why it is confusing.** Every rule you look at permits the traffic. The
outbound rule allows everything. The security group allows everything. The route
table is correct. The connection simply hangs and then times out — which looks
exactly like a routing problem.

The mechanism: a client opening a TCP connection picks an ephemeral source port.
The server's SYN-ACK is addressed **to that port**. A stateless filter has no
memory of the outbound SYN and evaluates the SYN-ACK on its own merits, where it
matches nothing.

**Which range?** 1024–65535 covers every operating system. Linux uses
32768–60999 by default (`/proc/sys/net/ipv4/ip_local_port_range`), Windows
49152–65535, and an ELB uses 1024–65535. Narrow it and you will break something
eventually.

**In production.** Someone hardens a network ACL by removing "unnecessary"
allow rules. Everything keeps working for hours because existing connections are
unaffected, and then new outbound connections start failing. This is *the*
classic network ACL mistake, and it is why security groups should be your first
tool and network ACLs a deliberate second layer.

---

## `broken-dns`

**Fault.** The VPC has `enableDnsSupport = false`. The Amazon-provided resolver
at the VPC base address plus two does not answer, so nothing resolves — private
hosted zones, VPC endpoint private DNS, or instance private DNS names.

**Confirm**

```bash
aws ec2 describe-vpc-attribute --region <region> --vpc-id <dns-vpc-id> --attribute enableDnsSupport
```

```json
{ "EnableDnsSupport": { "Value": false } }
```

**Fix** — in `main.tf`, on `module.dns_vpc`:

```hcl
enable_dns_support   = true
enable_dns_hostnames = true
```

**Why it is confusing.** Everything in Route 53 is correct and verifiable: the
zone exists, the record exists, the VPC association exists, and you can see all
three in the console. The fault is in a VPC attribute two screens away that
nobody thinks to check, because it is on by default and almost never changed.

**The two attributes do different things**

| Attribute | Effect when off |
| --- | --- |
| `enableDnsSupport` | The resolver at base+2 does not answer **at all**. Nothing resolves. |
| `enableDnsHostnames` | Instances get no public DNS name, and interface endpoint **private DNS cannot be enabled** |

Interface endpoints need **both**. Turning either off after the endpoints exist
does not delete them — they keep billing and stop being used, silently.

**In production.** A VPC created by a template that turned DNS off "for
security", or an old CloudFormation stack from before the defaults changed. The
symptom appears months later when someone adds a private hosted zone.

---

## `endpoint-policy`

**Fault.** The S3 gateway endpoint has a policy allowing only
`arn:aws:s3:::awsnet-lab10-approved`, a bucket that does not exist. The lab
bucket is not in the allow list, so requests to it are denied.

**Confirm**

```bash
terraform output -json investigation_starters | jq -r .vpc_endpoints | bash
terraform output -raw s3_bucket_name
```

The bucket name and the policy's `Resource` list do not match.

**Fix** — in `main.tf`, point the policy at the real bucket, or remove it
entirely (a null policy means full access, which is the AWS default):

```hcl
policy = jsonencode({
  Version = "2012-10-17"
  Statement = [{
    Effect    = "Allow"
    Principal = "*"
    Action    = ["s3:GetObject", "s3:ListBucket"]
    Resource  = [aws_s3_bucket.challenge[0].arn, "${aws_s3_bucket.challenge[0].arn}/*"]
  }]
})
```

**Why it is confusing.** There is no `Deny` statement anywhere. The denial is
**implicit** — an endpoint policy that allows only X denies everything else by
omission, so grepping for "Deny" finds nothing. The instance's IAM role has
`AmazonS3ReadOnlyAccess` and looks entirely sufficient.

**The rule:** an S3 request arriving through an endpoint is evaluated against
**both** the caller's IAM policy and the endpoint policy. Both must allow. The
endpoint policy grants nothing on its own.

**Telling the two apart:** an endpoint policy denial is fast and explicit
(`AccessDenied` in milliseconds). A missing route or missing association is a
**timeout** after ~60 seconds. Timing is the fastest diagnostic you have.

**In production.** A security team adds an endpoint policy to prevent
exfiltration to third-party buckets — correct and valuable — and misses a bucket
the workload legitimately needs. Often the Amazon Linux package repositories,
which is exactly the exercise in
[lab 03](../03-private-access-and-vpc-endpoints/README.md).

---

## `missing-association`

**Fault.** The S3 gateway endpoint is associated with the **public** route table
only. The private subnet's route table has no prefix-list route, so S3 traffic
from the private subnet follows the default route — of which there is none.

**Confirm**

```bash
terraform output -json investigation_starters | jq -r .vpc_endpoints | bash
terraform output -json investigation_starters | jq -r .all_route_tables | bash
```

The endpoint's `RouteTableIds` contains one ID. The private route table is not
it, and contains no `DestinationPrefixListId`.

**Fix** — in `main.tf`:

```hcl
gateway_endpoint_route_table_ids = module.base_vpc.all_route_table_ids
```

**Why it is confusing.** The endpoint's state is `available`, which sounds like
"working". Its console page shows it exists and is healthy. The security group
is irrelevant (gateway endpoints do not have one), the IAM role is correct, and
the bucket policy is correct.

A gateway endpoint is **a route**, not a device. With no route table entry
pointing at it, it has no effect on any packet.

`modules/vpc-endpoints` has a precondition that refuses an endpoint with *zero*
route tables, because that mistake is so common. This challenge therefore uses
the harder variant: associated with a route table, just not the one the traffic
uses. That version cannot be caught by a precondition, because there is no way
to know which route tables the caller intended.

**In production.** A VPC gains a subnet after the endpoint was created. The new
subnet's route table is never added to the endpoint's association list, and only
workloads in the new subnet are affected — so it looks intermittent.

---

## `asymmetric-routing`

**Fault.** `modules/vpc` creates one private route table per Availability Zone.
`app-a` (AZ 0) has a peering route; `app-b` (AZ 1) does not.

**Confirm**

```bash
aws ec2 describe-route-tables --region <region> \
  --filters Name=vpc-id,Values=<base-vpc-id> \
  --query 'RouteTables[].{Id:RouteTableId,Name:Tags[?Key==`Name`]|[0].Value,Subnets:Associations[].SubnetId,Peer:Routes[?VpcPeeringConnectionId!=null].DestinationCidrBlock}' \
  --output json
```

`rt-private-az0` has `10.101.0.0/16`. `rt-private-az1` does not.

**Fix** — add the route to every private route table:

```hcl
resource "aws_route" "app_to_peer" {
  for_each = module.base_vpc.private_route_table_ids

  route_table_id            = each.value
  destination_cidr_block    = var.peer_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peer[0].id
}
```

Note the shape of the fix: `for_each` over the map of route tables, so a route
table added later is covered automatically. Writing `aws_route` against one
hardcoded table ID is what created the problem.

**Why it is confusing.** The two subnets are configured identically — same VPC,
same security group, same NACL, same tags, adjacent CIDRs. Instances in them are
identical. Connectivity depends on which Availability Zone the instance happened
to land in, which under an Auto Scaling group means it depends on *when* it
launched.

The symptom in production is the worst kind: intermittent. Half your requests
work. Retries sometimes succeed. It looks like a flaky network.

**The trade-off this exposes.** Per-AZ private route tables are the right design
— they are what make per-AZ NAT gateways, per-AZ inspection routing and AZ
failure isolation possible. The cost is N places to keep in step, with no
warning when they diverge. Manage them with `for_each` over the route table map,
never one at a time.

---

## `flow-log-rejects`

**Fault.** Network ACL rule 90 denies TCP 8080 inbound to the private subnet.
The security group allows it.

**Confirm**

```bash
terraform output -raw flow_log_tail_command | bash
```

Generate the traffic from the client, wait about a minute, and look for:

```
2 123456789012 eni-0abc 10.100.0.87 10.100.10.42 43210 8080 6 3 180 ... REJECT OK
```

`REJECT` means the packet **arrived at an interface and was filtered**. Now
narrow down which filter:

```bash
terraform output -json investigation_starters | jq -r .all_security_group_rules | bash
terraform output -json investigation_starters | jq -r .network_acls | bash
```

The security group permits 8080 from the client group. The network ACL has rule
90 denying it, evaluated before rule 100 allows everything.

**Fix** — remove rule 90, or renumber it above 100 so the allow matches first.

**The diagnostic that makes this worth practising**

| Flow log shows | Conclusion | Where to look next |
| --- | --- | --- |
| `REJECT` | Filtered. **It arrived.** | Security groups, then NACLs |
| `ACCEPT` out, nothing back | Stateless filter dropping the reply | NACL inbound ephemeral rules |
| **Nothing at all** | Never arrived | **Routing** — route tables, peering, TGW, blackhole routes |
| `ACCEPT` both directions | The network delivered it | The application, or an OS firewall |

That table is the whole reason to enable flow logs. Without them, "connection
timed out" is indistinguishable between a missing route and a deny rule, and the
two have entirely different fixes.

**Reading NACLs correctly.** They are evaluated in ascending rule-number order
and **evaluation stops at the first match**. A deny at 90 makes an allow at 100
unreachable for the same traffic. Never read a network ACL as a set of rules —
read it top to bottom, like a routing table.

**In production.** Someone adds a deny rule for an incident and numbers it low
so it "definitely takes effect". The incident ends, the rule stays, and six
weeks later a new service on that port fails for no apparent reason.

---

## When you are done

```bash
terraform destroy
```

Then pick another challenge:

```hcl
challenges = ["nacl-ephemeral"]
```

```bash
terraform apply
```
