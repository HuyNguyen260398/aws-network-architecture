# Backend bootstrap

Creates the S3 bucket that stores Terraform state for every lab in this
repository.

Run this **once per AWS account and Region**, before any lab.

---

## The bootstrap problem, stated plainly

Every lab in this repository declares an S3 backend:

```hcl
terraform {
  backend "s3" {
    key          = "shop/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
```

Terraform cannot write state to a bucket that does not exist. So something has
to create the bucket first, and that something cannot itself use the bucket.

This module is that something. **It uses local state, on purpose.** That is the
only local-state exception in this repository, and it exists because there is no
other correct answer — the alternative is creating the bucket by hand in the
console, which this repository does not do.

Its `terraform.tfstate` file lands in this directory and is gitignored. If you
want it in S3 too, see [Migrating the bootstrap state](#migrating-the-bootstrap-state)
below — optional, and unnecessary for solo learning.

---

## What gets created

| Resource | Why |
| --- | --- |
| S3 bucket `<project>-tfstate-<random>` | Holds one state object per lab. |
| Versioning | Recovery path if a state object is corrupted or deleted. |
| Default SSE encryption | SSE-S3 (free) by default; SSE-KMS optional. |
| Block Public Access | All four settings on. State must never be readable publicly. |
| Bucket ownership `BucketOwnerEnforced` | ACLs disabled entirely. |
| Bucket policy: deny non-TLS | Rejects any request where `aws:SecureTransport` is `false`. |
| Lifecycle rules | Aborts stale multipart uploads; expires non-current versions after 90 days while always keeping the newest 5. |
| `prevent_destroy` on the bucket | Stops `terraform destroy` from taking your state with it. |
| KMS key + alias | Only when `create_kms_key = true`. |
| AWS Budget | Only when `enable_budget = true`. |

**Cost: effectively zero.** A few kilobytes of S3 storage. No NAT gateway, no
Transit Gateway, no VPC — this module creates no networking at all. The only way
to make it cost money is `create_kms_key = true` (~USD 1/month for the key).

State locking uses **S3 native locking** (`use_lockfile = true`), which writes a
`<key>.tflock` object for the duration of an operation. There is no DynamoDB
table here, because DynamoDB-based locking is deprecated and slated for removal.

---

## Prerequisites

- Terraform `>= 1.11.0`
- AWS credentials for a sandbox account
  (`aws sts get-caller-identity` should succeed)
- IAM permissions for `s3:CreateBucket`, `s3:PutBucket*`, `s3:GetBucket*`, plus
  `kms:*` on new keys and `budgets:*` if you enable those options

Authenticate however you normally do — this repository never asks for an access
key in a variable or a file:

```bash
export AWS_PROFILE=my-sandbox
# or
aws sso login --profile my-sandbox && export AWS_PROFILE=my-sandbox
```

---

## Deploy

```bash
cd bootstrap

cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars          # set aws_region, project_name, budget email

terraform init                    # local backend, no -backend-config needed
terraform plan
terraform apply
```

Then capture the values every lab needs:

```bash
terraform output -raw state_bucket_name
terraform output -raw state_bucket_region
terraform output -raw backend_hcl        # ready to paste into a lab's backend.hcl
```

Expected `backend_hcl` output:

```hcl
bucket       = "awsnet-tfstate-a1b2c3d4"
region       = "ap-southeast-1"
encrypt      = true
use_lockfile = true
```

---

## Wiring a lab to this backend

Each lab ships a `backend.hcl.example`. Fill it in once, in the first lab,
and copy the result into each later lab:

```bash
cd ../labs/01-single-server

cp backend.hcl.example backend.hcl
$EDITOR backend.hcl               # paste bucket + region from the output above

terraform init -backend-config=backend.hcl
```

`backend.hcl` is gitignored. The bucket name is specific to your account and
does not belong in version control.

Every lab's `backend.tf` hardcodes the **same `key`**, `shop/terraform.tfstate`.

That is deliberate. The labs are fourteen stages of one project, so they
describe the same infrastructure and share one state: applying lab 05 after
lab 04 upgrades what lab 04 built. See
[`docs/working-with-the-labs.md`](../docs/working-with-the-labs.md).

Sharing a key is only correct **because** the configurations describe the same
thing. Two unrelated projects sharing a key would overwrite each other's
state. If you fork this repository to build something else, give it a new
key — this is the one thing in the backend setup that will silently destroy
work if you get it wrong.

### Verifying the backend works

```bash
# The state object appears after your first apply.
aws s3 ls s3://$(terraform -chdir=../../bootstrap output -raw state_bucket_name)/labs/ --recursive

# Confirm encryption and versioning are actually on.
BUCKET=$(terraform -chdir=../../bootstrap output -raw state_bucket_name)
aws s3api get-bucket-encryption --bucket "$BUCKET"
aws s3api get-bucket-versioning --bucket "$BUCKET"
aws s3api get-public-access-block --bucket "$BUCKET"
```

### Seeing the lock in action

Run a long `terraform apply` in one terminal and `terraform plan` in another.
The second command reports a lock held by the first, and you can see the lock
object:

```bash
aws s3 ls s3://$BUCKET/shop/ --recursive
# ... terraform.tfstate
# ... terraform.tfstate.tflock     <- present only while an operation is running
```

If a process is killed mid-apply the lock object can survive. Confirm nobody
else is running Terraform, then `terraform force-unlock <LOCK_ID>` using the ID
from the error message.

---

## Migrating the bootstrap state

Optional. Useful for a shared or team account, where the bootstrap state should
not live on one person's laptop.

```bash
cd bootstrap

cp backend.tf.example  backend.tf
cp backend.hcl.example backend.hcl
$EDITOR backend.hcl               # fill in bucket + region

terraform init -backend-config=backend.hcl -migrate-state
# Terraform asks whether to copy existing state to the new backend. Answer yes.

terraform plan                    # must report no changes
```

Once `plan` is clean, the local `terraform.tfstate` is a stale backup. Keep it
until you are confident, then delete it.

There is a circular-looking property here that is worth understanding rather
than worrying about: the bucket is now managed by state stored *inside itself*.
That is fine in normal operation. It matters only when deleting the backend,
which is why the procedure below moves state back to local first.

To reverse the migration: delete `backend.tf` and run
`terraform init -migrate-state`.

---

## Deleting the backend

Do this only when you are finished with the whole repository, and **after every
lab has been destroyed**. Deleting the state bucket while labs still exist
orphans real AWS resources that you will then have to hunt down by hand.

```bash
# 1. Confirm no lab state objects remain.
BUCKET=$(terraform -chdir=bootstrap output -raw state_bucket_name)
aws s3 ls "s3://$BUCKET/labs/" --recursive
# Anything listed here means a lab is still deployed. Destroy it first.

# 2. If you migrated bootstrap state to S3, move it back to local, so Terraform
#    is not deleting the bucket that holds its own state.
cd bootstrap
rm backend.tf
terraform init -migrate-state
```

**3. Remove the destroy protection.** Edit `bootstrap/main.tf` and change:

```hcl
resource "aws_s3_bucket" "state" {
  lifecycle {
    prevent_destroy = true      # <- change to false, or delete the lifecycle block
  }
}
```

`prevent_destroy` is evaluated from the configuration, not from state, so it
must be changed in the file. There is no CLI flag to override it. This is
deliberate: a one-character edit is a low enough bar to be practical, and a high
enough bar that you cannot delete your state bucket by fat-fingering a command.

```bash
# 4. Empty the bucket, including every version. This is irreversible.
aws s3api delete-objects --bucket "$BUCKET" \
  --delete "$(aws s3api list-object-versions --bucket "$BUCKET" \
    --output json --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')" 2>/dev/null || true
aws s3api delete-objects --bucket "$BUCKET" \
  --delete "$(aws s3api list-object-versions --bucket "$BUCKET" \
    --output json --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}')" 2>/dev/null || true

# 5. Destroy.
terraform destroy
```

Restore `prevent_destroy = true` afterwards if you plan to bootstrap again.

---

## Troubleshooting

**`BucketAlreadyExists`** — S3 bucket names are globally unique across every AWS
account. Re-run `terraform apply`; `random_id` generates a new suffix. If you set
`state_bucket_name` explicitly, choose a different one.

**`Error: Failed to get existing workspaces: S3 bucket does not exist`** — you
ran a lab's `terraform init` before applying this module, or `backend.hcl` names
the wrong bucket or Region. Check `terraform -chdir=bootstrap output`.

**`AccessDenied` on `s3:PutObject` during a lab apply** — if you set
`deny_unencrypted_uploads = true`, the bucket policy requires the exact
server-side-encryption header. Confirm the lab's `backend.hcl` has
`encrypt = true`, and `kms_key_id` if you created a KMS key. Setting
`deny_unencrypted_uploads = false` is a safe fallback: default bucket encryption
still encrypts every object.

**`Error acquiring the state lock`** — another Terraform process holds it, or a
previous one died. Verify nobody else is running, then
`terraform force-unlock <LOCK_ID>`.

**`prevent_destroy` error on `terraform destroy`** — working as designed. See
[Deleting the backend](#deleting-the-backend).

---

## Further reading

- [S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3) — HashiCorp
- [Partial backend configuration](https://developer.hashicorp.com/terraform/language/backend#partial-configuration) — HashiCorp
- [`prevent_destroy`](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle#prevent_destroy) — HashiCorp
- [S3 Block Public Access](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html) — AWS
- [S3 default encryption](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-encryption.html) — AWS
- [S3 bucket policy examples](https://docs.aws.amazon.com/AmazonS3/latest/userguide/example-bucket-policies.html) — AWS
