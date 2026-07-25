terraform {
  # 1.9 is the first release whose variable validation may read anything beyond
  # the variable itself, which is how ansible_inventory_file and
  # bootstrap_ssh_source_ips reach the fleet contract.
  required_version = ">= 1.9.0"

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

locals {
  # The fleet contract — valid names, locations, and Ubuntu releases — lives in
  # one file shared with scripts/validate-inventory.py and the Ansible playbook,
  # so a new Hetzner location or Ubuntu release is added in one place.
  contract = jsondecode(file("${path.module}/../fleet-contract.json"))

  # Hetzner names its images after the release, so the supported image list
  # follows from the supported releases rather than repeating them.
  hcloud_images = [for version in keys(local.contract.ubuntu_releases) : "ubuntu-${version}"]

  inventory = yamldecode(file(var.ansible_inventory_file))

  # An absent hcloud_devboxes group, or a group written with no hosts under it,
  # means a fleet with no Hetzner hosts. A group present but written in the
  # wrong shape would land here as an empty fleet too, and an empty fleet plans
  # the deletion of every server that already exists — so ansible_inventory_file
  # checks the shape of both groups before OpenTofu evaluates any of this.
  hcloud_devboxes = try({
    for name, host in local.inventory.devboxes.children.hcloud_devboxes.hosts : name => {
      server_type       = try(host.hcloud_server_type, "")
      location          = try(host.hcloud_location, "")
      image             = try(host.hcloud_image, "")
      enable_public_ssh = try(host.hcloud_enable_public_ssh, null)
      delete_protection = try(host.hcloud_delete_protection, null)
    }
  }, {})

  manual_devbox_names = try(
    keys(local.inventory.devboxes.children.manual_devboxes.hosts),
    []
  )
}

resource "hcloud_ssh_key" "bootstrap" {
  name       = "devboxes-bootstrap"
  public_key = var.ssh_public_key
}

resource "hcloud_firewall" "devboxes" {
  for_each = local.hcloud_devboxes

  name = "${each.key}-firewall"

  # Bootstrap SSH, per host. Once Tailscale access is confirmed on a host, set
  # its hcloud_enable_public_ssh to false and re-apply: administration then goes
  # exclusively through Tailscale. A firewall per host means a new machine can
  # open bootstrap SSH without reopening it on the older ones.
  dynamic "rule" {
    for_each = each.value.enable_public_ssh == true ? [1] : []
    content {
      direction  = "in"
      protocol   = "tcp"
      port       = "22"
      source_ips = var.bootstrap_ssh_source_ips
    }
  }

  # Tailscale prefers direct WireGuard connections on UDP 41641. Everything
  # still works without this rule (DERP relays), but direct paths give much
  # better latency from mobile.
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

  # No inbound application ports: T3 Code binds to 127.0.0.1 and is reached
  # only through Tailscale Serve inside the tailnet.

  lifecycle {
    precondition {
      condition     = can(regex(local.contract.machine_name_pattern, each.key))
      error_message = "Each Hetzner host name must match devbox-<positive integer>."
    }

    precondition {
      condition     = !contains(local.manual_devbox_names, each.key)
      error_message = "${each.key} must not belong to both inventory child groups."
    }

    precondition {
      condition = (
        each.value.enable_public_ssh == true ||
        each.value.enable_public_ssh == false
      )
      error_message = "${each.key} must set hcloud_enable_public_ssh to true or false."
    }
  }
}

resource "hcloud_server" "devboxes" {
  for_each = local.hcloud_devboxes

  name        = each.key
  image       = each.value.image
  server_type = each.value.server_type
  location    = each.value.location

  ssh_keys     = [hcloud_ssh_key.bootstrap.id]
  firewall_ids = [hcloud_firewall.devboxes[each.key].id]

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    admin_user     = var.admin_user
    ssh_public_key = var.ssh_public_key
  })

  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  keep_disk          = true
  delete_protection  = each.value.delete_protection == true
  rebuild_protection = each.value.delete_protection == true

  lifecycle {
    # cloud-init changes would otherwise destroy and recreate the server.
    ignore_changes = [user_data]

    precondition {
      condition     = can(regex(local.contract.hcloud_server_type_pattern, each.value.server_type))
      error_message = "${each.key} must set a valid hcloud_server_type."
    }

    precondition {
      condition     = contains(local.contract.hcloud_locations, each.value.location)
      error_message = "${each.key} must set a valid hcloud_location."
    }

    precondition {
      condition     = contains(local.hcloud_images, each.value.image)
      error_message = "${each.key} must use a supported Ubuntu image."
    }

    precondition {
      condition = (
        each.value.delete_protection == true ||
        each.value.delete_protection == false
      )
      error_message = "${each.key} must set hcloud_delete_protection to true or false."
    }
  }
}

moved {
  from = hcloud_server.agent_vps
  to   = hcloud_server.devboxes["devbox-1"]
}

moved {
  from = hcloud_firewall.agent_vps
  to   = hcloud_firewall.devboxes["devbox-1"]
}
