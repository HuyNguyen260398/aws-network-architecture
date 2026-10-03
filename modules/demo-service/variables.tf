variable "services" {
  description = <<-EOT
    The stand-in applications to run on one host. Map keys become the service
    name reported in every response and the systemd unit name.

    `port` is the TCP port the service listens on. `upstream_url`, when set, is
    fetched on every request and its answer is embedded in the response, which
    turns a single `curl` into an end-to-end test of every hop behind it.

    An empty map installs the application script and starts nothing.
  EOT
  type = map(object({
    port         = number
    upstream_url = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for k, s in var.services : s.port >= 1 && s.port <= 65535])
    error_message = "Every service port must be between 1 and 65535."
  }

  validation {
    condition     = length(distinct([for k, s in var.services : s.port])) == length(var.services)
    error_message = "Two services on one host cannot listen on the same port. That is the whole point of ports: one IP address, many applications, told apart by port number."
  }

  validation {
    condition     = alltrue([for k, s in var.services : can(regex("^[a-z][a-z0-9-]{0,30}$", k))])
    error_message = "Service names must be lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "host_firewall_allowed_tcp_ports" {
  description = <<-EOT
    If not null, install nftables and load a host firewall that drops all
    inbound traffic except loopback, established connections, ICMP and these
    TCP ports. Null leaves the host with no firewall of its own.

    Installing nftables needs a path to the package repositories, so only set
    this on a host that has outbound internet access.
  EOT
  type        = list(number)
  default     = null
}
