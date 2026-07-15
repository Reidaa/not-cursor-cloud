terraform {
  required_version = ">= 1.6.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

resource "hcloud_ssh_key" "bootstrap" {
  name       = "${var.server_name}-bootstrap"
  public_key = var.ssh_public_key
}

resource "hcloud_firewall" "agent_vps" {
  name = "${var.server_name}-firewall"

  # Bootstrap SSH. After Tailscale access is confirmed (plan Step 3),
  # set enable_public_ssh = false and re-apply: administration then goes
  # exclusively through Tailscale (SSH over tailnet or Tailscale SSH).
  dynamic "rule" {
    for_each = var.enable_public_ssh ? [1] : []
    content {
      direction  = "in"
      protocol   = "tcp"
      port       = "22"
      source_ips = var.bootstrap_ssh_source_ips
    }
  }

  # Tailscale prefers direct WireGuard connections on UDP 41641.
  # Everything still works without this rule (DERP relays), but direct
  # paths give much better latency from mobile.
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "41641"
    source_ips = ["0.0.0.0/0"]
  }

  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0"]
  }

  # No inbound application ports: T3 Code binds to 127.0.0.1 and is
  # reached only through Tailscale Serve inside the tailnet.
}

resource "hcloud_server" "agent_vps" {
  name        = var.server_name
  image       = var.image
  server_type = var.server_type
  location    = var.location

  ssh_keys     = [hcloud_ssh_key.bootstrap.id]
  firewall_ids = [hcloud_firewall.agent_vps.id]

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    admin_user     = var.admin_user
    ssh_public_key = var.ssh_public_key
  })

  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  # cloud-init changes would otherwise destroy and recreate the server.
  lifecycle {
    ignore_changes = [user_data]
  }
}
