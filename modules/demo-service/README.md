# `modules/demo-service`

The stand-in applications the labs run: something listening on a port, and
nothing more.

It creates no AWS resources. It renders an EC2 **user-data script** that starts
one small Python HTTP server per service, and optionally a host firewall.

## Why a stand-in

The labs are about the network between applications, not the applications. A
real frontend, payment service and MySQL would add packages to install — which
a host in a private subnet cannot do — and nothing to learn.

Python 3 ships with Amazon Linux 2023, so the script works on a host with no
route to the internet at all.

## What a service answers

Every `GET` returns one line of JSON:

```json
{"service": "payment", "port": 9090, "host": "ip-10-10-10-14",
 "client_seen": "10.10.0.57", "path": "/",
 "forwarded_for": "198.51.100.23", "host_header": "pay.shop.test",
 "upstream": {"service": "database", "port": 3306, "client_seen": "10.10.10.14"}}
```

| Field | What it shows |
| --- | --- |
| `service`, `port` | Which application answered, on which port |
| `host` | Which host, container or pod answered — it changes between replicas |
| `client_seen` | The source address of the connection **as the server saw it**. This is what makes NAT, load balancers and PrivateLink visible |
| `forwarded_for` | The `X-Forwarded-For` header, when a load balancer added one |
| `host_header` | The `Host` header, for host-based routing |
| `upstream` | The answer from `upstream_url`, fetched on every request. One `curl` to the front of a chain exercises every hop behind it |
| `upstream_error` | Present instead of `upstream` when that hop failed — and says how |

## Usage

```hcl
module "web_apps" {
  source = "../../modules/demo-service"

  services = {
    frontend = { port = 80, upstream_url = "http://${module.app.private_ip}:9090/" }
  }

  # Only on a host that can reach a package repository.
  host_firewall_allowed_tcp_ports = [80]
}

module "web" {
  source    = "../../modules/test-instance"
  user_data = module.web_apps.user_data
  # ...
}
```

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `services` | `map(object({ port, upstream_url }))` | `{}` | Applications to run. The key is the service name. Two services cannot share a port. Empty installs the script and starts nothing |
| `host_firewall_allowed_tcp_ports` | `list(number)` | `null` | If set, install nftables and drop inbound traffic except loopback, established connections, ICMP and these ports |

## Outputs

| Name | Description |
| --- | --- |
| `user_data` | The script to pass as EC2 user data |
| `ports` | Map of service name to port |
| `app_script` | The application itself, as text — for a Kubernetes ConfigMap |
| `app_script_base64` | The same, base64-encoded — for a container environment variable |

## Notes

- The services run as root so they can bind ports below 1024. They are
  stand-ins on disposable hosts; a real service would not.
- The "database" is the same HTTP server on port 3306. It proves the port is
  reachable from where it should be and nowhere else, which is all the labs
  need from it.
- Nothing here is a secret, and nothing secret should be added: user data is
  readable from the instance metadata service.

## Tests

```bash
terraform init -backend=false && terraform test
```
