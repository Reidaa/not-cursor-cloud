mock_provider "hcloud" {
  mock_resource "hcloud_firewall" {
    defaults = {
      id = 1000
    }
  }
}

# Every run inherits these. A run that cares about a spec overrides devboxes.
variables {
  hcloud_token             = "test-token"
  ssh_public_key           = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest fleet@example.test"
  bootstrap_ssh_source_ips = ["1.1.1.1/32"]

  devboxes = {
    devbox-1 = {
      server_type       = "cx33"
      location          = "hel1"
      image             = "ubuntu-24.04"
      enable_public_ssh = false
      delete_protection = true
    }
  }
}

run "each_host_gets_one_server_and_one_firewall" {
  command = plan

  variables {
    devboxes = {
      devbox-1 = {
        server_type       = "cx33"
        location          = "hel1"
        image             = "ubuntu-24.04"
        enable_public_ssh = false
        delete_protection = true
      }
      devbox-2 = {
        server_type       = "cax31"
        location          = "fsn1"
        image             = "ubuntu-26.04"
        enable_public_ssh = true
        delete_protection = true
      }
    }
  }

  assert {
    condition     = length(hcloud_server.devboxes) == 2
    error_message = "A two-host fleet must create two Hetzner servers."
  }

  assert {
    condition     = length(hcloud_firewall.devboxes) == 2
    error_message = "A two-host fleet must create two Hetzner firewalls."
  }

  assert {
    condition     = toset(keys(hcloud_server.devboxes)) == toset(["devbox-1", "devbox-2"])
    error_message = "Each server must be keyed by its machine name."
  }

  assert {
    condition = (
      hcloud_server.devboxes["devbox-1"].name == "devbox-1" &&
      hcloud_server.devboxes["devbox-1"].image == "ubuntu-24.04" &&
      hcloud_server.devboxes["devbox-1"].server_type == "cx33" &&
      hcloud_server.devboxes["devbox-1"].location == "hel1" &&
      hcloud_server.devboxes["devbox-1"].delete_protection &&
      hcloud_server.devboxes["devbox-1"].rebuild_protection &&
      hcloud_server.devboxes["devbox-1"].keep_disk
    )
    error_message = "devbox-1 must use its spec and safety flags."
  }

  assert {
    condition = (
      strcontains(hcloud_server.devboxes["devbox-1"].user_data, "name: admin") &&
      strcontains(hcloud_server.devboxes["devbox-1"].user_data, "ssh_authorized_keys:") &&
      strcontains(hcloud_server.devboxes["devbox-1"].user_data, "package_upgrade: true") &&
      strcontains(hcloud_server.devboxes["devbox-1"].user_data, "power_state:")
    )
    error_message = "Cloud-init must create the first account and SSH access, then patch."
  }

  assert {
    condition = (
      hcloud_server.devboxes["devbox-2"].name == "devbox-2" &&
      hcloud_server.devboxes["devbox-2"].image == "ubuntu-26.04" &&
      hcloud_server.devboxes["devbox-2"].server_type == "cax31" &&
      hcloud_server.devboxes["devbox-2"].location == "fsn1"
    )
    error_message = "devbox-2 must use its spec."
  }

  assert {
    condition = alltrue([
      for name, firewall in hcloud_firewall.devboxes :
      length([
        for rule in firewall.rule : rule
        if rule.protocol == "udp" &&
        rule.port == "41641" &&
        rule.source_ips == toset(["0.0.0.0/0"])
      ]) == 1
    ])
    error_message = "Every firewall must allow direct Tailscale UDP traffic."
  }

  assert {
    condition = alltrue([
      for name, firewall in hcloud_firewall.devboxes :
      length([
        for rule in firewall.rule : rule
        if rule.protocol == "icmp" &&
        rule.source_ips == toset(["0.0.0.0/0"])
      ]) == 1
    ])
    error_message = "Every firewall must allow ICMP."
  }

  assert {
    condition = (
      length([
        for rule in hcloud_firewall.devboxes["devbox-1"].rule : rule
        if rule.protocol == "tcp" && rule.port == "22"
      ]) == 0 &&
      length([
        for rule in hcloud_firewall.devboxes["devbox-2"].rule : rule
        if rule.protocol == "tcp" &&
        rule.port == "22" &&
        rule.source_ips == toset(var.bootstrap_ssh_source_ips)
      ]) == 1
    )
    error_message = "Public SSH must follow each host flag and use the restricted ranges."
  }

  assert {
    condition     = hcloud_ssh_key.bootstrap.name == "devboxes-bootstrap"
    error_message = "The fleet must share one bootstrap SSH key."
  }

  assert {
    condition     = toset(keys(output.devboxes)) == toset(["devbox-1", "devbox-2"])
    error_message = "The output must contain one entry per Hetzner host."
  }

  assert {
    condition = (
      output.devboxes["devbox-1"].image == "ubuntu-24.04" &&
      output.devboxes["devbox-1"].server_type == "cx33" &&
      output.devboxes["devbox-1"].admin_user == "admin" &&
      output.devboxes["devbox-2"].image == "ubuntu-26.04" &&
      output.devboxes["devbox-2"].server_type == "cax31"
    )
    error_message = "The output map must return each host's spec."
  }
}

run "an_empty_fleet_creates_no_resources" {
  command = plan

  variables {
    devboxes = {}
  }

  assert {
    condition     = length(hcloud_server.devboxes) == 0
    error_message = "An empty fleet must create no servers."
  }

  assert {
    condition     = length(hcloud_firewall.devboxes) == 0
    error_message = "An empty fleet must create no firewalls."
  }
}

run "invalid_name_fails_before_create" {
  command = plan

  variables {
    devboxes = {
      devbox-01 = {
        server_type       = "cx33"
        location          = "hel1"
        image             = "ubuntu-24.04"
        enable_public_ssh = false
        delete_protection = true
      }
    }
  }

  expect_failures = [
    hcloud_firewall.devboxes["devbox-01"],
  ]
}

run "invalid_image_fails_before_create" {
  command = plan

  variables {
    devboxes = {
      devbox-1 = {
        server_type       = "cx33"
        location          = "hel1"
        image             = "ubuntu-22.04"
        enable_public_ssh = false
        delete_protection = true
      }
    }
  }

  expect_failures = [
    hcloud_server.devboxes["devbox-1"],
  ]
}

run "invalid_location_fails_before_create" {
  command = plan

  variables {
    devboxes = {
      devbox-1 = {
        server_type       = "cx33"
        location          = "atlantis"
        image             = "ubuntu-24.04"
        enable_public_ssh = false
        delete_protection = true
      }
    }
  }

  expect_failures = [
    hcloud_server.devboxes["devbox-1"],
  ]
}

run "invalid_server_type_fails_before_create" {
  command = plan

  variables {
    devboxes = {
      devbox-1 = {
        server_type       = "biggest one please"
        location          = "hel1"
        image             = "ubuntu-24.04"
        enable_public_ssh = false
        delete_protection = true
      }
    }
  }

  expect_failures = [
    hcloud_server.devboxes["devbox-1"],
  ]
}

run "ipv4_default_route_cannot_open_ssh" {
  command = plan

  variables {
    bootstrap_ssh_source_ips = ["1.2.3.4/0"]
  }

  expect_failures = [
    var.bootstrap_ssh_source_ips,
  ]
}

run "placeholder_ssh_range_fails_direct_plan" {
  command = plan

  variables {
    bootstrap_ssh_source_ips = ["203.0.113.10/32"]
  }

  expect_failures = [
    var.bootstrap_ssh_source_ips,
  ]
}
