# Design: AWS Networking Learning Labs

Date: 2026-08-06
Status: Approved. **Partly superseded on 2026-10-03** -- see below.

> **Superseded 2026-10-03.** The labs are no longer independently deployable.
> They were restructured into fourteen stages of one project (an online shop)
> that share a single state key, `shop/terraform.tfstate`, with each lab
> upgrading the previous lab's deployment. Three labs were added (load
> balancing, containers, Kubernetes) to cover the concepts in the video
> "Every Networking Concept Explained In 20 Minutes". The lab list, backend
> keys and the goal "each lab initialises, applies, verifies, and destroys on
> its own" below describe the earlier design. The current design is in
> `docs/working-with-the-labs.md`. Toolchain, bootstrap, cost gating and the
> module conventions are unchanged.

## Purpose

A Git repository that teaches AWS networking through independently deployable Terraform
labs, progressing from a single VPC to multi-VPC, hybrid, secure, and observable
architectures. The deliverable is a learning artifact, not a production workload.

The AWS Certified Advanced Networking – Specialty (ANS-C01) exam retires on
2026-08-25. Its four domains supply a useful curriculum skeleton, but the labs are
organised around durable networking concepts, not around exam objectives.

## Goals

- Every AWS resource is declared in Terraform. No console clicks, no `aws ... create`.
- Each lab initialises, applies, verifies, and destroys on its own.
- Chargeable resources are off by default and require a deliberate second opt-in.
- Documentation explains why a design was chosen, not only how to run it.

## Non-goals

- Production-grade landing zone or multi-account org structure.
- CI that applies or destroys infrastructure.
- Simulating AWS resources that cannot honestly be created (see Direct Connect).

## Toolchain and version pinning

Verified 2026-08-06:

| Component | Choice | Reason |
| --- | --- | --- |
| Terraform | `>= 1.11.0, < 2.0.0` | 1.11 is where S3 native locking (`use_lockfile`) is the supported mechanism and `dynamodb_table` is deprecated. Cross-variable `validation` (1.9+) and `mock_provider` (1.7+) are also required. |
| AWS provider | `~> 6.0`, locked at 6.58.0 | Current major. `.terraform.lock.hcl` committed with multi-platform hashes. |
| TFLint | 0.58.0 + `terraform` ruleset | Enforces naming, typed variables, documented outputs. |
| Checkov | 3.2.x | Static security scanning. |

## State backend

`bootstrap/` is a root module using **local state** — the only intentional exception,
because the remote backend must exist before Terraform can consume it. It creates:

- An S3 bucket named `<prefix>-tfstate-<random_id>` (name overridable). A random suffix
  rather than the account ID, so the bucket name does not leak the account number and
  is not guessable.
- Versioning, SSE (AES256 by default, optional customer-managed KMS key), Block Public
  Access, `aws:SecureTransport = false` deny policy, and a deny on unencrypted `PutObject`.
- `lifecycle { prevent_destroy = true }` on the bucket, with documented removal steps.

Every lab carries a `backend.tf` with a partial S3 configuration — a hardcoded unique
`key`, `use_lockfile = true`, `encrypt = true` — and no bucket or region. Those are
supplied at init time via `terraform init -backend-config=backend.hcl`. This keeps
account-specific values out of version control and lets CI run `init -backend=false`.

Backend keys follow `labs/<NN-lab-name>/terraform.tfstate`.

## Reusable modules

Modules exist only where a shape recurs across three or more labs.

| Module | Responsibility |
| --- | --- |
| `modules/vpc` | VPC, subnets, route tables, IGW, optional NAT (none/single/per-AZ), optional IPv6 + egress-only IGW, default-SG lockdown. |
| `modules/test-instance` | SSM-managed EC2. IMDSv2 required, encrypted root volume, no key pair, no inbound rules by default. |
| `modules/vpc-endpoints` | Gateway and interface endpoints with optional endpoint policies and a managed security group. |
| `modules/flow-logs` | VPC Flow Logs to CloudWatch Logs or S3, configurable format and retention. |
| `modules/budget` | AWS Budgets alarm. Disabled by default, opt-in email. |

### `modules/vpc` subnet interface

Subnets are declared as a **map of objects**, not parallel lists:

```hcl
public_subnets = {
  "public-a" = { cidr_block = "10.0.0.0/24", az_index = 0 }
  "public-b" = { cidr_block = "10.0.1.0/24", az_index = 1 }
}
```

Map keys give `for_each` stable resource addresses that survive reordering, and the
learner controls AZ placement explicitly. There is no separate "isolated" subnet type:
a private subnet with no NAT route already is one, which reinforces the lab-02 lesson
that routing — not naming — determines a subnet's reachability.

AZ names come from `data.aws_availability_zones` filtered to `opt-in-not-required`;
`az_index` indexes into that list. AMIs come from `data.aws_ami` (owner `amazon`,
name filter `al2023-ami-2023.*-kernel-6.1-<arch>`) rather than the
`/aws/service/ami-al2023/...` SSM public parameters, because some restricted IAM
policies deny the `/aws/` Parameter Store namespace.

## Labs

Every lab is a standalone root module. Conceptual ordering only:
`01 → 02 → {03, 04} → {05, 06} → {07, 08} → 09 → 10`.

| # | Lab | Core teaching point |
| --- | --- | --- |
| 01 | vpc-fundamentals | CIDR planning, AZs, subnets, route tables, IGW, SG vs NACL, optional IPv6. Zero chargeable resources. |
| 02 | public-private-subnets | A subnet is public because of its route to an IGW. NAT GW and egress-only IGW optional. |
| 03 | private-access-and-vpc-endpoints | S3 gateway endpoint (free) vs interface endpoints (hourly). Endpoint policies, private DNS, NAT-vs-endpoint break-even. |
| 04 | vpc-peering | Non-overlapping CIDRs, no transitive routing (demonstrated with a third VPC), cross-account notes, comparison table vs TGW and PrivateLink. |
| 05 | transit-gateway | Hub-and-spoke, attachments, TGW route tables, association vs propagation, segmentation, blackhole routes. Fully opt-in. |
| 06 | dns-and-privatelink | Private hosted zones, split-horizon DNS, Resolver endpoints and rules (opt-in), a real PrivateLink endpoint service backed by an NLB (opt-in). |
| 07 | hybrid-networking | CGW, VGW, Site-to-Site VPN, static vs BGP, redundant tunnels. Opt-in **real** simulated on-premises: a second VPC with a strongSwan instance configured from the actual tunnel parameters, so tunnels genuinely come UP. Direct Connect is documented; a real (free) DX Gateway resource is offered, but no physical connection is faked. |
| 08 | security-and-observability | SG vs NACL statefulness, Flow Logs, Reachability Analyzer, CloudTrail relevance, Network Firewall (opt-in), WAF/Shield/mirroring concepts. |
| 09 | multi-region-networking | Inter-region VPC peering across two provider aliases, optional TGW peering, Route 53 and Global Accelerator/CloudFront concepts and cost trade-offs. |
| 10 | troubleshooting-challenges | One root module, a `challenges` set variable enabling individually broken scenarios. `HINTS.md` and `SOLUTIONS.md` are separate files. |

## Cost and safety controls

Two-key model. An expensive resource needs both its own feature flag and a global
acknowledgement:

```hcl
variable "acknowledge_costs" { type = bool, default = false }

variable "enable_nat_gateway" {
  type    = bool
  default = false
  validation {
    condition     = !var.enable_nat_gateway || var.acknowledge_costs
    error_message = "Set acknowledge_costs = true to create hourly-billed resources."
  }
}
```

Cross-variable references in `validation` require Terraform 1.9+, already satisfied.

Additional controls: `t4g.nano` instances, CloudWatch log retention defaulting to 1 day,
no Elastic IPs unless a NAT gateway or VPN demands one, single-AZ copies of expensive
services unless the lab specifically teaches HA, cost warnings surfaced in Terraform
`outputs` as well as in each README, and a cleanup checklist for resources that can
survive a partial destroy. `prevent_destroy` appears only on the backend bucket.

## Quality gates

`make check` runs, and CI reproduces: `terraform fmt -check -recursive`,
`terraform init -backend=false && terraform validate` for every root and child module,
`tflint --recursive`, `checkov`, and `terraform test` for modules. Module tests use
`mock_provider "aws"` with `mock_data` overrides for `aws_availability_zones` and
`aws_ami`, so they run with no AWS credentials. CI never applies.

## Accepted trade-offs

- Lab 07's strongSwan configuration is rendered from the AWS-generated tunnel
  pre-shared keys, which land in Terraform state. State is encrypted at rest in S3, and
  the outputs are marked sensitive; the README says so plainly.
- Direct Connect virtual interfaces cannot be created without a real cross-connect. The
  lab ships the architecture, the Terraform interfaces, and a free DX Gateway, and
  documents what a learner would need to go further.
- Lab 10 deliberately deploys misconfigured infrastructure. Every scenario is confined
  to its own VPC, uses private subnets, and creates nothing internet-reachable.
