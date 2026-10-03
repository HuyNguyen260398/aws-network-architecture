output "user_data" {
  description = "Shell script to pass as EC2 user data. Starts every service and, if requested, the host firewall."
  value       = local.user_data
}

output "ports" {
  description = "Map of service name to the TCP port it listens on."
  value       = { for name, svc in var.services : name => svc.port }
}

output "app_script_base64" {
  description = "The stand-in application itself, base64-encoded, for callers that run it somewhere other than a systemd unit -- a container, for example."
  value       = base64encode(file("${path.module}/files/app.py"))
}

output "app_script" {
  description = "The stand-in application as plain text, for embedding in a Kubernetes ConfigMap."
  value       = file("${path.module}/files/app.py")
}
