# Solutions

**Stop.** If you have not yet formed your own diagnosis and written it down,
go back. Reading a solution first converts a thirty-minute lesson into a
thirty-second one that will not stick.

Each solution gives the cause in one sentence, the evidence that proves it,
the fix in Terraform, and what to remember. When you have applied a fix and
seen the symptom go, restore the file with `git checkout challenges.tf`.

---

## `missing-route`

**Cause.** The shop's route tables have a route to the partner VPC through
the peering connection; the partner's route table has no route back.

**Evidence.**

```bash
aws ec2 describe-route-tables --filters Name=tag:Name,Values='shop-partner*' \
  --query 'RouteTables[].Routes[].{Dest:DestinationCidrBlock,Pcx:VpcPeeringConnectionId,Gw:GatewayId}' --output table
```

Only `local` and `0.0.0.0/0 → igw`. With flow logs on the partner VPC you
would see the request **ACCEPT**ed: it arrived. The reply to `10.10.x.x`
matched the default route and was sent to the internet gateway, which
discarded it.

**Fix.** In `challenges.tf`, create the return route whenever the partner VPC
exists:

```hcl
resource "aws_route" "partner_to_shop" {
  count = local.need_partner_vpc ? 1 : 0     # was: ... && !local.c.missing_route
  ...
}
```

**Remember.** A connection is two one-way paths. `active` is a property of
the peering connection, not of the traffic. Check routes on **both** sides,
in **every** route table.

---

## `security-group`

**Cause.** The partner host's rule for TCP 8080 allows `10.11.0.0/16`. The
shop is `10.10.0.0/16`. One digit.

**Evidence.**

```bash
aws ec2 describe-security-group-rules --filters Name=tag:Name,Values='shop-partner*' \
  --query 'SecurityGroupRules[?!IsEgress].{Proto:IpProtocol,Port:FromPort,Source:CidrIpv4}' --output table
```

`icmp` from `10.10.0.0/16`, `tcp 8080` from `10.11.0.0/16`. Ping working
proved routing in both directions, which is why the route tables were a dead
end.

**Fix.** In `challenges.tf`, in `module "partner_host"`:

```hcl
cidr_ipv4 = var.vpc_cidr     # was: a conditional that produced 10.11.0.0/16
```

**Remember.** A successful ping tells you routing works and nothing about
any TCP port. A rule that looks right at a glance is exactly the rule to read
character by character. This is the argument for referencing security groups
or prefix lists instead of typing ranges.

---

## `nacl-ephemeral`

**Cause.** An outbound rule numbered 90 on the data-tier network ACL denies
TCP 1024–65535 to the VPC. It is evaluated before the allow at 100, so the
database's **replies** are dropped.

**Evidence.**

```bash
eval "$(terraform output -raw verify_nacl)"
```

Egress rule 90, `deny`, ports 1024–65535. In flow logs: `ACCEPT` for
`app → db:3306` and `REJECT` for `db:3306 → app:<high port>`.

**Fix.** Delete `aws_network_acl_rule.challenge_data_out_deny_ephemeral` from
`challenges.tf`.

**Remember.** ACCEPT one way and REJECT the other on the same flow is the
signature of a **stateless** filter. A security group cannot produce it. The
request and the reply are separate decisions for a network ACL, and the reply
goes to an ephemeral port.

---

## `wrong-next-hop`

**Cause.** The public route table has a route for `10.10.10.0/24` — the app
subnet — pointing at the database host's network interface. It is more
specific than `10.10.0.0/16 → local`, so it wins. The database host is not a
router and discards the packets.

**Evidence.**

```bash
aws ec2 describe-route-tables --route-table-ids "$(terraform output -raw public_route_table_id)" \
  --query 'RouteTables[0].Routes[].{Dest:DestinationCidrBlock,Target:NetworkInterfaceId,Gw:GatewayId}' --output table
```

A `/24` with an `eni-…` target. Flow logs: nothing on the app interface; on
the **database** interface, rejected packets addressed to an app-tier
address. Reachability Analyzer names the route in one step.

**Fix.** Delete `aws_route.challenge_wrong_next_hop` from `challenges.tf`.

**Remember.** "The local route is there" is not the same as "the local route
is used". Longest prefix match applies inside a VPC, which is how firewalls
are inserted on purpose (lab 08) and how traffic is hijacked by accident.
**No record at the destination means routing.**

---

## `broken-dns`

**Cause.** A second private hosted zone named `app.shop.internal` is
associated with the shop VPC. When more than one private zone could answer,
the most specific zone name wins, so inside the shop VPC it shadows the `app`
record in `shop.internal` and returns an address where nothing listens.

**Evidence.**

```bash
aws route53 list-hosted-zones --query 'HostedZones[?Config.PrivateZone].{Name:Name,Comment:Config.Comment}' --output table
aws route53 get-hosted-zone --id <the app.shop.internal zone> --query 'VPCs'
```

Two zones cover the name. The shadow zone is associated with the shop VPC
only, which is why the dev host — associated with `shop.internal` alone —
still gets the right answer.

**Fix.** Delete `aws_route53_zone.challenge_shadow` and
`aws_route53_record.challenge_shadow` from `challenges.tf`.

**Remember.** DNS answers depend on **where you ask from**. "It resolves
correctly for me" is not evidence about another VPC. Works-by-address,
fails-by-name is always DNS, and the first command is `dig` **on the failing
host**.

---

## `listener-rule-order`

**Cause.** A listener rule with priority 1 matches the path `/p*` and
forwards to the frontend. Rules are evaluated lowest number first and the
first match wins, so `/pay/*` — priority 10 — is never reached.

**Evidence.**

```bash
terraform output -json verify_load_balancer | jq -r .listener_rules | sh
```

Priority 1, `/p*`, frontend target group. `curl …/promo` is also answered by
the frontend. The host-based rule still works because the request's path is
`/`, which `/p*` does not match.

**Fix.** In `challenges.tf`, delete `aws_lb_listener_rule.challenge_catch_all`,
or give it a priority above 20 so the payment rules are evaluated first.

**Remember.** Healthy targets say nothing about routing rules. Ordered,
first-match rule lists — listener rules, network ACLs, firewall policies,
Ingress paths — all fail the same way: a broad rule placed above a narrow
one. When adding a rule, read the ones above it.
