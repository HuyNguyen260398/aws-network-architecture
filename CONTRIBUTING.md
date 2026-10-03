# Contributing

Thanks for helping improve these labs. This repository optimises for one thing:
a learner should be able to read a lab, deploy it, understand what happened, and
destroy it without a surprise bill.

## Before you start

```bash
# One-time
pip install pre-commit checkov
brew install terraform tflint gitleaks   # or your platform's equivalent
make precommit-install

# Before every pull request
make check
```

`make check` runs formatting, validation, TFLint, Checkov, and the module and
lab tests — exactly what CI runs.

## Ground rules

**Terraform declares everything.** If a lab needs an AWS resource, it goes in a
`.tf` file. Never instruct a learner to click through the console or to run
`aws ... create-*`. AWS CLI commands are welcome in verification and
troubleshooting sections, where they read state rather than change it.

**Nothing expensive is on by default.** Any resource with an hourly or
per-GB-processed charge needs its own `enable_*` variable defaulting to `false`,
plus a validation that refuses to create it unless `acknowledge_costs = true`.
See `enable_nat_gateway` in `labs/03-nat-and-outbound/nat.tf` for the pattern.

**No secrets, ever.** No credentials, account IDs, bucket names, ARNs from your
own account, state files, plan files, or private keys. `.gitignore` and the
gitleaks hook catch most of it; you are the backstop for the rest.

**Every lab folder is complete.** The labs are stages of one project and share
one state, but each folder contains the whole configuration for its stage: it
must apply to an empty state and destroy cleanly without any other folder.
No `remote_state` data sources between labs.

**No misleading resources.** If something cannot honestly be created in a
learning account — a Direct Connect cross-connect, for instance — document the
architecture and the Terraform interface, and say plainly that the physical
piece is out of scope. Do not create a decorative resource that pretends.

## Terraform style

Each root module contains, where applicable:

```
terraform.tf   required_version and required_providers
providers.tf   provider blocks, default_tags
backend.tf     partial S3 backend config, unique key
variables.tf   typed, described, validated
locals.tf      naming and tagging
main.tf        the actual architecture
outputs.tf     described; sensitive marked
terraform.tfvars.example
backend.hcl.example
README.md
```

- Every variable has a `type` and a `description`. Add `validation` wherever a
  wrong value would produce a confusing AWS error instead of a clear Terraform one.
- Every output has a `description`. Anything derived from a pre-shared key,
  password, or private key is `sensitive = true`.
- Prefer `for_each` over `count` so resource addresses survive reordering.
- Never hardcode AZ names or AMI IDs. Use `data.aws_availability_zones` and
  `data.aws_ami`.
- Use `precondition` / `postcondition` / `check` blocks where they make a
  networking invariant explicit — they teach as well as protect.
- Comment *networking decisions*, not Terraform syntax. `# NAT is single-AZ so
  the lab costs one gateway, not three` is useful. `# create a subnet` is not.

## How the labs are organised

The labs are **one project at fourteen stages**, not fourteen projects. Read
[`docs/working-with-the-labs.md`](docs/working-with-the-labs.md) first. In
short:

- Every lab folder is the whole project at that stage and shares one state
  key, `shop/terraform.tfstate`.
- Lab N+1 is lab N plus one or two new files, named for what they add. Each
  file holds its own variables, resources and outputs.
- Earlier files are copied forward **unchanged** unless the new lab has to
  alter them. `make lab-diff FROM=<lab> TO=<lab>` shows what differs.

## Changing an existing lab

A fix to a file in lab N must be made in **every later lab's copy** of that
file. After editing, check them:

```bash
make lab-diff FROM=03-nat-and-outbound TO=14-troubleshooting-challenges
```

A file that should be identical must not appear in the output.

## Adding a lab

1. Copy the **last** lab folder to a new one with the next number.
2. Leave `backend.tf` alone: the state key is shared on purpose.
3. Put the new stage in a new file. Change an existing file only when the new
   stage has to, and say why in a comment at the top of that file.
4. Every chargeable resource gets an `enable_*` flag, off by default — by
   lab 14 everything earlier is still deployed, so nothing may assume it is
   the only thing running.
5. Add the new flags to `terraform.tfvars.example` and to both runs in
   `tests/plan.tftest.hcl`.
6. Write the README before the Terraform. If you cannot explain the traffic
   flow, the architecture is not ready. State what changed from the previous
   lab.
7. Add the lab to the table in the root `README.md`, to
   `docs/learning-path.md`, `docs/working-with-the-labs.md` and
   `docs/cost-guide.md`.
8. Run `make check`.

Lab READMEs must contain: learning objectives, concepts, a Mermaid architecture
diagram, traffic-flow explanation, resources created, cost, prerequisites,
deployment steps, verification commands with expected output, hands-on
exercises, troubleshooting exercises, cleanup, and links to official AWS docs.

## Adding a module

Modules live in `modules/` and earn their place by being used in three or more
labs. Two callers is usually a sign the code should stay inline where a learner
can read it. Add `tests/*.tftest.hcl` using `mock_provider` so the tests run
without AWS credentials.

## Commit messages

Conventional Commits: `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`,
`test:`, `ci:`. Scope with the lab or module where it helps —
`feat(labs/10): add blackhole route example`.

## Reporting problems

Open an issue with the lab name, your Terraform and AWS provider versions, the
region, and the exact error. Redact account IDs, ARNs, and IP addresses.
Security issues go to `SECURITY.md` instead.
