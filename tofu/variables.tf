variable "hcloud_token" {
  description = "Hetzner Cloud API token. Pass via TF_VAR_hcloud_token; never commit it."
  type        = string
  sensitive   = true
}

variable "server_name" {
  description = "Name of the VPS (also used for firewall and SSH key names)."
  type        = string
  default     = "agent-vps"

  validation {
    condition     = can(regex("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$", var.server_name))
    error_message = "server_name must be a lowercase DNS label."
  }
}

variable "server_type" {
  description = "Hetzner server type. CX33 = 4 vCPU / 8 GB / 80 GB, matching the plan's minimum. Availability fluctuates — run `just check-availability` first."
  type        = string
  default     = "cx33"
}

variable "location" {
  description = "Hetzner location (nbg1, fsn1, hel1, ...)."
  type        = string
  default     = "nbg1"
}

variable "image" {
  description = "OS image. This repository currently supports Ubuntu 24.04 only."
  type        = string
  default     = "ubuntu-24.04"

  validation {
    condition     = var.image == "ubuntu-24.04"
    error_message = "Only ubuntu-24.04 is currently supported by the Ansible roles."
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
  description = "Bootstrap SSH public key (contents of ~/.ssh/id_ed25519.pub)."
  type        = string
}

variable "enable_public_ssh" {
  description = "Keep public SSH open. Set to false once Tailscale access is verified (plan Step 3)."
  type        = bool
}

variable "bootstrap_ssh_source_ips" {
  description = "IPv4 CIDRs allowed to reach public SSH during bootstrap. Use your current public IP/32."
  type        = list(string)

  validation {
    condition = (
      length(var.bootstrap_ssh_source_ips) > 0 &&
      alltrue([for cidr in var.bootstrap_ssh_source_ips : can(cidrnetmask(cidr))]) &&
      !contains(var.bootstrap_ssh_source_ips, "0.0.0.0/0")
    )
    error_message = "Provide at least one restricted IPv4 CIDR; 0.0.0.0/0 is not allowed."
  }
}
