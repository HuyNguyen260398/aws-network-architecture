# Hints

Read these **only when you are stuck**, and only for the challenge you are
working on. Each has three hints in increasing order of specificity — take the
first and go back to the terminal before reading the second.

Answers are in [SOLUTIONS.md](SOLUTIONS.md). Try not to.

---

## A method that works for all of them

1. **How does it fail?** Timeout, refusal, denial, or a wrong answer.
2. **Can the packet get there, and back?** Route tables, on **both** sides.
3. **Is something dropping it?** Security groups, then network ACLs.
4. **Is the name resolving to the right thing?** From the host that is failing.
5. **Is the right thing answering?** The application, or whatever routes to it.

Flow logs separate steps 2 and 3: a `REJECT` means it arrived and was
filtered; **no record at all** means it never arrived.

---

## `missing-route`

<details>
<summary>Hint 1</summary>

`active` describes the peering connection. It says nothing about whether any
subnet is using it. What else has to exist before a packet moves — and how
many of them?
</details>

<details>
<summary>Hint 2</summary>

Your request may well be arriving. What does the partner host do with its
**reply**? Follow the reply through the partner's route table, line by line.
</details>

<details>
<summary>Hint 3</summary>

```bash
aws ec2 describe-route-tables --filters Name=tag:Project,Values=shop \
  --query 'RouteTables[].{Name:Tags[?Key==`Name`]|[0].Value,Peered:Routes[?VpcPeeringConnectionId!=`null`].DestinationCidrBlock}' --output table
```

One VPC's route tables know about the other. Compare with the partner's.
</details>

---

## `security-group`

<details>
<summary>Hint 1</summary>

Ping works. So routing is fine, in both directions, and you can stop looking
at route tables. What is different between an ICMP packet and a TCP packet to
port 8080, as far as the network is concerned?
</details>

<details>
<summary>Hint 2</summary>

Something is filtering by protocol and port. The partner VPC has no custom
network ACL. Look at the rule that is supposed to allow port 8080 — all of
it, not just the port.
</details>

<details>
<summary>Hint 3</summary>

```bash
aws ec2 describe-security-group-rules --filters Name=tag:Name,Values='shop-partner*' \
  --query 'SecurityGroupRules[?!IsEgress].{Proto:IpProtocol,Port:FromPort,Source:CidrIpv4}' --output table
```

Read the two source ranges character by character.
</details>

---

## `nacl-ephemeral`

<details>
<summary>Hint 1</summary>

The frontend and the payment service still answer, so most of the path is
healthy. The error is a **timeout**, reported by the payment service, about
the database. That is one hop.
</details>

<details>
<summary>Hint 2</summary>

Run the lab 08 `traffic_to_the_database` flow-log query. The request to port
3306 is **ACCEPT**ed. So the database received it. Now look for the reply:
same two addresses, reversed, destination port in the high range.
</details>

<details>
<summary>Hint 3</summary>

ACCEPT inbound and REJECT outbound for the same connection cannot be a
security group — they are stateful. Only one kind of filter treats the two
directions separately.

```bash
eval "$(terraform output -raw verify_nacl)"
```

Read the **egress** rules in number order.
</details>

---

## `wrong-next-hop`

<details>
<summary>Hint 1</summary>

Check whether the app host is reachable from anywhere else: from the database
host, or from the app host itself (`curl http://127.0.0.1:9090/`). If it is,
the app host is fine and the problem is specific to where the web server's
packets go.
</details>

<details>
<summary>Hint 2</summary>

Flow logs on the app host's interface show **no record** of the web server's
attempts. The packets never arrive. That is routing — but the `local` route
is present. What can beat a route that is present?
</details>

<details>
<summary>Hint 3</summary>

```bash
aws ec2 describe-route-tables --route-table-ids "$(terraform output -raw public_route_table_id)" \
  --query 'RouteTables[0].Routes' --output table
```

Look for a destination **smaller** than the VPC's `/16`, and at what it
points to.
</details>

---

## `broken-dns`

<details>
<summary>Hint 1</summary>

By address it works; by name it fails. The network path is therefore fine.
Compare `dig +short app.shop.internal` on the web server with the app host's
real address.
</details>

<details>
<summary>Hint 2</summary>

The record in `shop.internal` is correct — check it. And the dev host gets
the right answer from the same zone. So the web server's answer is coming
from somewhere else. What differs between the two hosts, as far as DNS is
concerned?
</details>

<details>
<summary>Hint 3</summary>

```bash
aws route53 list-hosted-zones --query 'HostedZones[?Config.PrivateZone].{Name:Name,Id:Id,Comment:Config.Comment}' --output table
```

Look for a zone whose name is *longer* than `shop.internal`, and at which
VPCs it is associated with.
</details>

---

## `listener-rule-order`

<details>
<summary>Hint 1</summary>

The payment target group is healthy, and `curl -H 'Host: pay.shop.test'`
still reaches the payment service. So the service and its target group are
fine. Only requests selected by **path** go wrong.
</details>

<details>
<summary>Hint 2</summary>

A load balancer evaluates its rules in order and stops at the first match.
The rule for `/pay/*` still exists. Is it still the first one that matches
`/pay/checkout`?
</details>

<details>
<summary>Hint 3</summary>

```bash
terraform output -json verify_load_balancer | jq -r .listener_rules | sh
```

Sort by priority. Try `curl http://<load balancer>/promo` as well.
</details>
