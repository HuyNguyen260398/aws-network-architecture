# Working with the labs

The fourteen labs are not fourteen projects. They are **one project — a small
online shop — at fourteen stages of its life.** Each lab folder holds the whole
project as it stands at that stage, and each one improves on the network the
previous lab built.

This page explains what that means in practice.

---

## One project

The shop is the example from the video the first labs follow: a web
**frontend** (port 80), a **payment** service (port 9090) and a **database**
(port 3306). They are stand-ins — tiny HTTP servers that report who they are
and who called them — because the subject is the network between them.

| Lab | What the shop's network gains |
| --- | --- |
| 01 | One server on the internet, two applications on two ports |
| 02 | Three tiers in separate subnets, each reachable only from the one in front |
| 03 | Outbound internet access for the private tiers, through NAT |
| 04 | Private access to S3 and Systems Manager, without NAT |
| 05 | A load balancer: one stable entry point, host- and path-based routing |
| 06 | Containers: a Docker bridge network, then ECS with VPC-native addresses |
| 07 | Kubernetes: pod addresses, Services, Ingress |
| 08 | Flow logs, Reachability Analyzer, CloudTrail, Network Firewall |
| 09 | Two more VPCs, joined by peering |
| 10 | A Transit Gateway **replaces** the peering |
| 11 | Private DNS names, and PrivateLink for one service |
| 12 | The office, over a Site-to-Site VPN |
| 13 | A second Region |
| 14 | Faults, injected on request |

## One state

Every lab's `backend.tf` uses the **same state key**, `shop/terraform.tfstate`.
That is deliberate, and it is the opposite of what you would do for unrelated
projects.

Because the state is shared, `terraform apply` in lab 05 does not build a
second shop next to lab 04's. It compares lab 05's configuration with what
already exists and makes the difference — which is exactly "what this lab
adds". **The plan is the lesson.** Read it before you approve it.

## One folder at a time

Each lab folder is complete: every `.tf` file the project needs at that
stage. Lab N+1 is lab N plus one or two new files, and sometimes an edit to an
old one.

| File | Arrives in | Changes in |
| --- | --- | --- |
| `network.tf`, `compute.tf`, `dns.tf` | 01 | 02, 03, 05 |
| `nacl.tf` | 02 | — |
| `nat.tf` | 03 | — |
| `endpoints.tf` | 04 | — |
| `load-balancing.tf` | 05 | — |
| `containers.tf` | 06 | — |
| `kubernetes.tf`, `k8s/` | 07 | — |
| `observability.tf`, `firewall.tf` | 08 | — |
| `more-vpcs.tf`, `peering.tf` | 09 | `peering.tf` is **removed** in 10 |
| `transit-gateway.tf` | 10 | — |
| `private-dns.tf`, `privatelink.tf` | 11 | — |
| `hybrid.tf`, `templates/` | 12 | — |
| `multi-region.tf` | 13 | `providers.tf` gains a second Region |
| `challenges.tf`, `HINTS.md`, `SOLUTIONS.md` | 14 | — |

To see exactly what a lab changes:

```bash
make lab-diff FROM=04-private-aws-access TO=05-load-balancing
```

Each file keeps its own variables and outputs next to the resources they
belong to, so a new file is a complete unit you can read top to bottom.

---

## Moving from one lab to the next

```bash
cd labs/05-load-balancing

cp ../04-private-aws-access/backend.hcl .
cp ../04-private-aws-access/terraform.tfvars .
diff terraform.tfvars terraform.tfvars.example    # what this lab adds

terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

- **`backend.hcl`** is identical in every lab. Copy it.
- **`terraform.tfvars`** accumulates. Each lab's `terraform.tfvars.example`
  contains every earlier lab's settings plus its own; carry your file forward
  and add the new ones.
- **Do not `terraform destroy` between labs.** The next lab needs what this
  one built.

### Starting in the middle

You can begin at any lab: apply it to an empty state and it builds everything
up to that stage in one go. You lose the incremental plans, not the result.

### Going backwards

Applying an earlier lab over a later one removes whatever the later labs
added — Terraform sees resources in the state that the configuration no
longer describes. Two cautions:

- From **lab 13** onward the state contains resources in a second Region.
  Earlier folders have no provider for that Region and cannot plan against
  that state. Go back no further than lab 13, or destroy first.
- From **lab 07**, delete the Kubernetes objects with `kubectl` before
  removing the cluster. The load balancer the Ingress created is not in
  Terraform's state.

---

## Cost: everything accumulates

A single shared project means that by lab 14 **every earlier lab's resources
still exist**. Two rules keep that affordable.

**Chargeable resources are off by default**, each behind its own `enable_*`
flag and the shared `acknowledge_costs = true`. Applying every lab with the
defaults costs about USD 0.07/hour — a handful of `t4g.nano` instances.

**Turn an opt-in off when you move on.** A flag set in lab 03 is still set in
lab 09 unless you change it. Before each lab, look through
`terraform.tfvars` for flags you no longer need:

| Flag | Lab | Hourly |
| --- | --- | --- |
| `enable_nat_gateway` | 03 | USD 0.059 |
| `enable_interface_endpoints` | 04 | USD 0.033 |
| `enable_load_balancer` | 05 | USD 0.035 |
| `enable_ecs` | 06 | USD 0.024 |
| `enable_eks` | 07 | USD 0.20–0.25 |
| `enable_network_firewall` | 08 | **USD 0.395** |
| `enable_transit_gateway` | 10 | USD 0.15 |
| `enable_privatelink` | 11 | USD 0.036 |
| `enable_resolver_*_endpoint` | 11 | **USD 0.25 each** |
| `enable_site_to_site_vpn` | 12 | USD 0.076 |
| `enable_transit_gateway_peering` | 13 | USD 0.10 |

Everything switched on at once is over USD 1.60/hour. See
[`cost-guide.md`](cost-guide.md).

## Destroying

Destroy **from the folder you applied last**. It is the only folder whose
configuration matches the state.

```bash
terraform destroy
```

Then check nothing with the project tag remains, in both Regions if you
reached lab 13:

```bash
for R in ap-southeast-1 ap-northeast-1; do
  aws resourcegroupstaggingapi get-resources --region $R \
    --tag-filters Key=Project,Values=shop \
    --query 'ResourceTagMappingList[].ResourceARN' --output text
done
```

---

## Checks without an AWS account

Every lab has a `tests/plan.tftest.hcl` that plans it against a mocked AWS
provider — once with the defaults and once with every opt-in enabled.

```bash
cd labs/05-load-balancing
terraform init -backend=false
terraform test
```

`make check` runs these for every lab, along with formatting, validation,
TFLint and Checkov. None of it needs credentials, and none of it creates
anything. **It is not a substitute for applying**: a mocked plan proves the
configuration is coherent, not that AWS accepts it.

## Keeping the folders in step

Because each folder is a full copy, a fix to `nat.tf` has to be made in lab 03
and in every later lab. Check for drift between two labs' copies of a file
with:

```bash
make lab-diff FROM=03-nat-and-outbound TO=14-troubleshooting-challenges
```

Files that are meant to be identical should not appear in the output.
