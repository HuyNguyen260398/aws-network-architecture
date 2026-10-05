# Runbook

Every command used while working through the labs, in one place. The lab
READMEs explain *why*; this page is the copy-and-paste reference.

Commands read their values from `terraform output`, so nothing here needs an
instance ID or address pasted in. Run them from the lab folder you applied
last, unless a section says **on the server**.

---

## Before any lab

```bash
terraform version                  # >= 1.11.0
aws sts get-caller-identity        # which account and identity am I using?
aws configure get region
session-manager-plugin --version   # needed for a shell on a host
curl -s https://checkip.amazonaws.com   # my public IP, for allowed_client_cidr
```

## State backend (once per account)

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # then edit
terraform init
terraform plan
terraform apply

terraform output -raw state_bucket_name
terraform output -raw backend_hcl              # contents for every lab's backend.hcl
```

## Deploying a lab

```bash
cd labs/01-single-server

terraform -chdir=../../bootstrap output -raw backend_hcl > backend.hcl
cp terraform.tfvars.example terraform.tfvars   # then edit; carry it forward from lab to lab

terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Check a lab without credentials or cost (mocked provider):

```bash
terraform init -backend=false && terraform test
```

## Looking at what is deployed

```bash
terraform output                    # everything
terraform output verify_compute     # ready-made check commands, values filled in
terraform output verify_network
terraform state list                # every resource in the shared state
```

Everything the project created, by tag:

```bash
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=shop \
  --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n'

aws resourcegroupstaggingapi get-resources --tag-filters Key=Repo,Values=aws-network-handons \
  --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n'
```

## A shell on a host

```bash
$(terraform output -raw ssm_server)
# i.e. aws ssm start-session --target <instance id> --region <region>
```

`TargetNotConnected` straight after an apply means the SSM agent has not
registered yet. Wait a minute and retry.

---

## Lab 01 — a single server

### 1. Two applications, one address

```bash
curl -s "$(terraform output -raw frontend_url)"   # port 80
curl -s "$(terraform output -raw payment_url)"    # same address, port 9090
```

Expect the frontend's JSON to embed the payment service's under `upstream`.
`client_seen` is your public IP for the outer call and `127.0.0.1` for the
inner one.

### 2. Public address outside, private address inside

```bash
terraform output server_public_ip server_private_ip
```

On the server:

```bash
ip -4 addr show                         # only 10.10.0.x -- no public address on the host
curl -s https://checkip.amazonaws.com   # ...yet the internet sees the public one
```

### 3. What is listening

On the server:

```bash
sudo ss -ltnp              # python3 on 0.0.0.0:80 and 0.0.0.0:9090
sudo nft list ruleset      # the host firewall: allows 80 and 9090
```

From your machine — a filtered port times out, a closed one is refused:

```bash
curl -v --max-time 5 "http://$(terraform output -raw server_public_ip):22/"   # timeout: security group drops it
```

Security group rules, as AWS sees them:

```bash
aws ec2 describe-security-group-rules \
  --filters Name=group-id,Values="$(aws ec2 describe-instances \
      --instance-ids "$(terraform output -raw server_instance_id)" \
      --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)" \
  --query 'SecurityGroupRules[].{Egress:IsEgress,Proto:IpProtocol,From:FromPort,To:ToPort,Cidr:CidrIpv4}' \
  --output table
```

### 4. The name

```bash
NAME=$(aws ec2 describe-instances --instance-ids "$(terraform output -raw server_instance_id)" \
  --query 'Reservations[0].Instances[0].PublicDnsName' --output text)
echo "$NAME"
dig +short "$NAME"         # resolves to server_public_ip
curl -s "http://$NAME/"    # same shop, reached by name

terraform output shop_hostname   # your own name, if public_zone_name is set
```

### 5. The route that makes the subnet public

```bash
aws ec2 describe-route-tables --route-table-ids "$(terraform output -raw public_route_table_id)" \
  --query 'RouteTables[0].Routes' --output table
```

Two routes: `10.10.0.0/16 → local` and `0.0.0.0/0 → igw-…`.

Subnets and free addresses (256 − 5 reserved − your instances):

```bash
aws ec2 describe-subnets --filters Name=tag:Project,Values=shop \
  --query 'Subnets[].{CIDR:CidrBlock,AZ:AvailabilityZone,Free:AvailableIpAddressCount}' --output table
```

---

## Cleanup

Moving on to the next lab: **do not destroy** — the next lab builds on this one.

Finished for now, from the folder you applied last:

```bash
terraform destroy

aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=shop \
  --query 'ResourceTagMappingList[].ResourceARN' --output text    # empty means clean
```

The state bucket from `bootstrap/` is kept on purpose (`prevent_destroy`).
