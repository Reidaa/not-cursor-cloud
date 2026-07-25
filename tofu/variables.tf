variable "hcloud_token" {
  description = "Hetzner Cloud API token. Pass via TF_VAR_hcloud_token; never commit it."
  type        = string
  sensitive   = true
}

variable "ansible_inventory_file" {
  description = "Fleet inventory. OpenTofu reads only its hcloud_devboxes group."
  type        = string
  default     = "../ansible/inventory/hosts.yml"

  validation {
    # A group written with no hosts under it decodes to null, which is allowed
    # and simply means the group is empty. An absent group decodes to the
    # "missing" sentinel, and any other shape is a typo; keys() rejects both. A
    # list or a string here would otherwise read as a fleet with no hosts, which
    # plans the deletion of every existing server.
    condition = fileexists(var.ansible_inventory_file) ? alltrue([
      for hosts in [
        try(yamldecode(file(var.ansible_inventory_file)).devboxes.children.hcloud_devboxes.hosts, "missing"),
        try(yamldecode(file(var.ansible_inventory_file)).devboxes.children.manual_devboxes.hosts, "missing"),
      ] : hosts == null || can(keys(hosts))
    ]) : false
    error_message = "ansible_inventory_file must contain both DevBox child groups, each holding a map of hosts."
  }
}

variable "admin_user" {
  description = "Initial admin account created by cloud-init and used by Ansible."
  type        = string
  default     = "admin"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]*$", var.admin_user))
    error_message = "admin_user must be a valid lowercase Linux username."
  }
}

variable "ssh_public_key" {
  description = "Bootstrap SSH public key."
  type        = string

  validation {
    condition = (
      can(regex("^ssh-(ed25519|rsa|ecdsa-[^ ]+) [A-Za-z0-9+/=]+", var.ssh_public_key)) &&
      !can(regex("(?i)(replace|placeholder)", var.ssh_public_key))
    )
    error_message = "ssh_public_key must contain a real OpenSSH public key."
  }
}

variable "bootstrap_ssh_source_ips" {
  description = "IPv4 CIDRs allowed to reach public SSH during bootstrap."
  type        = list(string)

  validation {
    condition = (
      length(var.bootstrap_ssh_source_ips) > 0 &&
      alltrue([
        for cidr in var.bootstrap_ssh_source_ips :
        try(cidrnetmask(cidr) != "0.0.0.0", false) &&
        can(regex("^[0-9.]+/[0-9]+$", cidr)) &&
        # The documentation ranges are the ones .env.example ships, so rejecting
        # them here catches an unedited example. The prefixes come from the
        # fleet contract that doctor.sh and validate-inventory.py also read.
        !anytrue([
          for prefix in jsondecode(file("${path.module}/../fleet-contract.json")).documentation_ipv4_prefixes :
          startswith(cidr, prefix)
        ])
      ]) &&
      !contains(var.bootstrap_ssh_source_ips, "0.0.0.0/0")
    )
    error_message = "Provide real, restricted IPv4 CIDRs; IPv4 /0 ranges are not allowed."
  }
}
