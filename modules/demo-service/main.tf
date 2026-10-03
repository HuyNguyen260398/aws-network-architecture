# A stand-in for a real application.
#
# Networking labs need something listening on a port, and nothing more. This
# renders a user-data script that starts one tiny Python HTTP server per
# service. Python 3 ships with Amazon Linux 2023, so the script works on a host
# with no route to the internet at all -- which several labs depend on.
#
# Each response is a line of JSON naming the service, the port it listened on,
# the host that answered and the client address the server saw. That last field
# is what makes NAT and load balancers visible: it shows whose address the
# packet carried when it arrived.

locals {
  user_data = templatefile("${path.module}/files/user-data.sh.tftpl", {
    app_b64        = base64encode(file("${path.module}/files/app.py"))
    services       = var.services
    firewall_ports = var.host_firewall_allowed_tcp_ports
  })
}
