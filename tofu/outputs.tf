output "server_ipv4" {
  description = "Public IPv4 of the VPS (bootstrap SSH target for Ansible)."
  value       = hcloud_server.agent_vps.ipv4_address
}

output "server_status" {
  value = hcloud_server.agent_vps.status
}

output "admin_user" {
  description = "Bootstrap account used by Ansible."
  value       = var.admin_user
}

output "server_name" {
  description = "Configured VPS and Tailscale hostname."
  value       = var.server_name
}

output "ssh_bootstrap_command" {
  value = "ssh ${var.admin_user}@${hcloud_server.agent_vps.ipv4_address}"
}
