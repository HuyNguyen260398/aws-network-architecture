# Tests for modules/demo-service.
#
# The module has no providers and no resources: it renders a shell script.
# These runs check the script says what the inputs asked for.
#
#   terraform init -backend=false && terraform test

run "two_services_and_a_firewall" {
  command = plan

  variables {
    services = {
      frontend = { port = 80, upstream_url = "http://127.0.0.1:9090/" }
      payment  = { port = 9090 }
    }
    host_firewall_allowed_tcp_ports = [80, 9090]
  }

  assert {
    condition     = startswith(output.user_data, "#!/bin/bash")
    error_message = "User data must start with a shebang or cloud-init will not run it."
  }

  assert {
    condition     = strcontains(output.user_data, "app.py frontend 80 http://127.0.0.1:9090/")
    error_message = "The frontend unit must start the app on port 80 with its upstream."
  }

  assert {
    condition     = strcontains(output.user_data, "tcp dport { 80, 9090 } accept")
    error_message = "The host firewall must allow exactly the requested ports."
  }

  assert {
    condition     = output.ports == { frontend = 80, payment = 9090 }
    error_message = "The ports output must map each service to its port."
  }
}

run "no_firewall_by_default" {
  command = plan

  variables {
    services = {
      database = { port = 3306 }
    }
  }

  assert {
    condition     = !strcontains(output.user_data, "nftables")
    error_message = "No host firewall should be installed unless ports are given."
  }
}

run "no_services_installs_only_the_script" {
  command = plan

  assert {
    condition     = !strcontains(output.user_data, "systemctl enable")
    error_message = "With no services there must be no systemd units."
  }

  assert {
    condition     = strcontains(output.user_data, "/opt/shop/app.py")
    error_message = "The application script must still be written to disk."
  }
}

run "two_services_cannot_share_a_port" {
  command = plan

  variables {
    services = {
      one = { port = 8080 }
      two = { port = 8080 }
    }
  }

  expect_failures = [var.services]
}
