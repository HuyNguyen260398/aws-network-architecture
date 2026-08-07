# Security Policy

## What this repository is

A teaching repository. The Terraform here is written to be secure by default,
but it is designed for a disposable learning account — not for production.

**Deploy these labs in a sandbox AWS account you can afford to lose.** Several
labs deliberately create misconfigured infrastructure (all of `labs/10`), and
every lab expects to be destroyed within hours.

## Reporting a vulnerability

If you find a security problem in this repository — a lab that exposes something
publicly, a leaked credential in history, an IAM policy that is broader than it
needs to be — please report it privately:

1. Open a [GitHub security advisory](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
   on this repository, or
2. Email the maintainers listed in `CODEOWNERS` if one exists.

Please do not open a public issue for anything that would let someone else
exploit a learner's account. Expect an acknowledgement within a week.

**Do not report AWS service vulnerabilities here.** Those go to
<https://aws.amazon.com/security/vulnerability-reporting/>.

## Security properties this repository maintains

These are enforced by code and checked in CI. If you find one violated, that is
a bug worth reporting.

| Property | How it is enforced |
| --- | --- |
| No SSH from the internet | No lab opens port 22 to `0.0.0.0/0`. Instance access is via AWS Systems Manager Session Manager. No EC2 key pairs are created. |
| IMDSv2 required | `modules/test-instance` sets `http_tokens = "required"` and `http_put_response_hop_limit = 1`. |
| Encryption at rest | EBS root volumes are encrypted. The state bucket enforces SSE. Flow log destinations support customer-managed KMS keys. |
| Encryption in transit | The state bucket denies any request where `aws:SecureTransport` is `false`. |
| No public S3 | Block Public Access is enabled on every bucket this repository creates. |
| Least-privilege IAM | Instance roles carry `AmazonSSMManagedInstanceCore` and nothing more. Flow log roles are scoped to the specific log group. |
| Default security group locked | `modules/vpc` strips all rules from the VPC's default security group. |
| No secrets in git | `.gitignore` excludes state, plans, tfvars, and key material. `gitleaks` runs in pre-commit and in CI over full history. |

## Things you must handle yourself

**Terraform state contains secrets.** State is a plaintext record of every
attribute Terraform manages, including values marked `sensitive` in outputs.
Concretely, `labs/07-hybrid-networking` puts AWS-generated Site-to-Site VPN
pre-shared keys into state. Treat the state bucket as a secret store:

- Keep Block Public Access on.
- Restrict `s3:GetObject` on the state bucket to the identities that need it.
- Do not copy state files to your laptop, a ticket, or a chat message.

**Credentials are yours to manage.** This repository never asks for an access
key in a variable, a tfvars file, or a provider block. Authenticate with an
`AWS_PROFILE`, AWS IAM Identity Center (SSO), or an assumed role. Prefer
short-lived credentials.

**The IAM permissions to run these labs are broad.** Creating VPCs, Transit
Gateways, IAM roles, and VPN connections requires substantial privilege. Use a
dedicated sandbox account rather than granting these permissions in an account
that holds anything real.

**Destroy your labs.** An abandoned NAT gateway, VPN connection, or Network
Firewall endpoint costs money every hour and widens your exposure. See the
cleanup checklist in `docs/cost-guide.md`.

## Supported versions

The `main` branch is the only supported version. Terraform `>= 1.11.0` and AWS
provider `~> 6.0` are required; older combinations are untested and the S3
native state locking used here will not work below Terraform 1.10.
