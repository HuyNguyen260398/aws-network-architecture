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

`make check` runs formatting, validation, TFLint, Checkov, and the module tests
— exactly what CI runs.

## Ground rules

**Terraform declares everything.** If a lab needs an AWS resource, it goes in a
`.tf` file. Never instruct a learner to click through the console or to run
`aws ... create-*`. AWS CLI commands are welcome in verification and
troubleshooting sections, where they read state rather than change it.

**Nothing expensive is on by default.** Any resource with an hourly or
per-GB-processed charge needs its own `enable_*` variable defaulting to `false`,
plus a validation that refuses to create it unless `acknowledge_costs = true`.
See `labs/02-public-private-subnets/variables.tf` for the pattern.

**No secrets, ever.** No credentials, account IDs, bucket names, ARNs from your
own account, state files, plan files, or private keys. `.gitignore` and the
gitleaks hook catch most of it; you are the backstop for the rest.

**Every lab stands alone.** A lab must be deployable and destroyable without any
other lab existing. Cross-lab references belong in prose, not in `remote_state`
data sources.

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

## Adding a lab

1. Copy the closest existing lab as a starting point.
2. Give it a unique backend key in `backend.tf`
   (`labs/<NN-name>/terraform.tfstate`). Duplicate keys silently corrupt state.
3. Write the README before the Terraform. If you cannot explain the traffic
   flow, the architecture is not ready.
4. Add the lab to the table in the root `README.md` and to `docs/learning-path.md`.
5. Add its chargeable resources to `docs/cost-guide.md`.
6. Run `make check`.

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
`feat(labs/05): add blackhole route example`.

## Reporting problems

Open an issue with the lab name, your Terraform and AWS provider versions, the
region, and the exact error. Redact account IDs, ARNs, and IP addresses.
Security issues go to `SECURITY.md` instead.
