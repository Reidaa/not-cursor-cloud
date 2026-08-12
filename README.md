<div align="center">

# not-cursor-cloud

**Create and manage private remote coding hosts with OpenTofu, Ansible, and Tailscale.**

[![CI](https://github.com/Reidaa/not-cursor-cloud/actions/workflows/ci.yml/badge.svg)](https://github.com/Reidaa/not-cursor-cloud/actions/workflows/ci.yml)

[Overview](#overview) · [Quick start](#quick-start) · [Use a DevBox](#use-a-devbox) · [Manage the fleet](#manage-the-fleet) · [Development](#development)

</div>

`not-cursor-cloud` manages a fleet of remote coding hosts called DevBoxes. OpenTofu creates Hetzner hosts. Ansible configures all hosts.

Each DevBox includes:

- [Herdr](https://herdr.dev/)
- [T3 Code](https://github.com/pingdotgg/t3code)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- [Codex CLI](https://github.com/openai/codex)
- [OpenCode](https://opencode.ai/)
- [GitHub CLI](https://cli.github.com/)
- [mise](https://mise.jdx.dev/)
- Tailscale SSH

> [!WARNING]
> `just apply` creates paid infrastructure. Review the OpenTofu plan and current Hetzner prices before you approve it.

## Overview

The repository separates fleet membership from host creation:

```text
OpenTofu or a manual provider
            │
            ▼
      Ubuntu DevBox
            │
            ▼
         Ansible
            │
            ├── security updates and SSH hardening
            ├── Tailscale and Tailscale SSH
            ├── non-sudo agent account
            └── coding tools and T3 Code
```

OpenTofu manages Hetzner servers and firewalls. A manual provider records hosts that you created elsewhere. Ansible applies the same setup to both.

The Hetzner firewall permits these inbound connections:

- SSH from the IPv4 ranges that you specify during bootstrap
- Tailscale traffic on UDP port `41641`
- ICMP traffic

The firewall does not expose T3 Code on the public network. T3 Code uses port `3773` and remains available through the tailnet.

## Supported setup

The project supports these DevBox targets:

- Ubuntu 24.04 or 26.04
- x86-64 or ARM64
- Hetzner Cloud or an existing host

The current controller setup uses macOS. You also need a Tailscale account and a Hetzner account for Hetzner hosts.

## Prerequisites

Install these tools on the controller:

- [OpenTofu](https://opentofu.org/)
- [uv](https://docs.astral.sh/uv/)
- [just](https://github.com/casey/just)
- `jq`
- OpenSSH

On macOS, run:

```bash
brew install opentofu uv just jq
```

For Hetzner hosts, you also need:

- A Hetzner Cloud project
- A read-write API token
- An SSH key pair
- Your current public IPv4 address

## Quick start

### 1. Prepare the repository

```bash
git clone https://github.com/Reidaa/not-cursor-cloud.git
cd not-cursor-cloud
just setup
```

`just setup` creates the local files from tracked examples. It does not replace existing files.

### 2. Set credentials

Edit `.env`:

```dotenv
TF_VAR_hcloud_token=<hetzner-api-token>
TAILSCALE_AUTHKEY=
TF_VAR_ssh_public_key="ssh-ed25519 <public-key> you@example.com"
TF_VAR_bootstrap_ssh_source_ips='["198.51.100.10/32"]'
TF_VAR_admin_user=admin
AGENT_TIMEZONE=UTC
AGENT_USER=agent
```

Replace the example IPv4 address with your current public address. Use a `/32` suffix to permit only that address.

Leave `TAILSCALE_AUTHKEY` empty for manual Tailscale enrollment. Otherwise, use a short-lived key and revoke it after bootstrap.

> [!CAUTION]
> Do not commit `.env`, OpenTofu state, host specifications, or manual host addresses. These files can contain secrets.

### 3. Define the fleet

Add each host name to `ansible/inventory/hosts.yml`:

```yaml
---
devboxes:
  vars:
    ansible_user: admin

  hosts:
    devbox-1:
```

Host names must match `devbox-N`, where `N` is a positive integer.

For each Hetzner host, add a specification to `fleet/providers/hcloud/devboxes.auto.tfvars.json`:

```json
{
  "devboxes": {
    "devbox-1": {
      "server_type": "cx33",
      "location": "nbg1",
      "image": "ubuntu-26.04",
      "enable_public_ssh": true,
      "delete_protection": true
    }
  }
}
```

The inventory defines fleet membership. The provider specification defines how Hetzner creates each host.

### 4. Create the host

```bash
just doctor
just init
just check-availability devbox-1
just plan
just apply
just bootstrap devbox-1
```

`just doctor` checks tools, credentials, file permissions, host names, providers, and account names. `just bootstrap` waits for SSH and runs Ansible.

### 5. Enroll Tailscale manually

Skip this section if you set `TAILSCALE_AUTHKEY`.

Get the public address and connect to the host:

```bash
ssh admin@$(tofu -chdir=fleet/providers/hcloud output -json devboxes | jq -r '."devbox-1".ipv4')
sudo tailscale up --hostname devbox-1 --ssh
exit
```

Make sure that MagicDNS resolves the host. Then complete the setup:

```bash
ssh admin@devbox-1 true
just configure devbox-1
just smoke devbox-1
```

After Tailscale works, set `enable_public_ssh` to `false`. Then review and apply the firewall change.

## Use a DevBox

### Connect to the agent account

The playbook creates a passwordless `agent` account without sudo access. Your tailnet policy must permit Tailscale SSH to this account.

```bash
ssh agent@devbox-1
cd ~/workspaces
```

Conventional OpenSSH permits only the admin account. Tailscale SSH provides access to the agent account.

### Run Herdr

Start Herdr from a project directory:

```bash
herdr
```

Herdr keeps its terminal sessions after you disconnect. Run `herdr` again to attach to the session.

### Authenticate the coding tools

Authentication stays on the DevBox and does not enter infrastructure state.

```bash
ssh admin@devbox-1
sudo -iu agent
codex login --device-auth
claude auth login
opencode auth login
```

The playbook also adds aliases that skip permission prompts:

| Alias | Command |
| --- | --- |
| `claude-yolo` | `claude --dangerously-skip-permissions` |
| `codex-yolo` | `codex --dangerously-bypass-approvals-and-sandbox` |
| `opencode-yolo` | `opencode --auto` |

The plain commands keep their normal prompts. Use the unrestricted aliases only inside the non-sudo agent account.

### Authenticate GitHub

Configure Git and GitHub as the agent user:

```bash
ssh admin@devbox-1
sudo -iu agent
git config --global user.name "Your Name"
git config --global user.email "your-github-email@example.com"
gh auth login --web --git-protocol https
gh auth setup-git
gh auth status
```

Use an account or token with access only to the required repositories.

### Pair T3 Code

Create a pairing token as the agent user:

```bash
ssh admin@devbox-1
sudo -u agent -H /usr/local/bin/t3 auth pairing create \
  --base-url "http://devbox-1.<your-tailnet>.ts.net:3773" \
  --ttl 10m \
  --label "browser"
```

Open the printed pair URL before it expires. You can also enter these values in **Add Environment**:

```text
Host: http://devbox-1.<your-tailnet>.ts.net:3773
Pairing code: <token>
```

Each token works once. Create a new token for each browser, device, or environment entry. Treat each token as a password.

If you lose all admin browser sessions, restart T3 Code and read the startup URL:

```bash
sudo systemctl restart t3code
sudo journalctl -u t3code --since "2 minutes ago" -o cat --no-pager
```

Replace `http://0.0.0.0:3773` in that URL with the tailnet address. Open the changed URL within five minutes.

### Install more tools with mise

The playbook enables mise in interactive Bash sessions. Use `mise use -g` to install and select a tool:

```bash
mise use -g uv just
```

## Manage the fleet

### Common commands

| Command | Purpose |
| --- | --- |
| `just doctor` | Check local tools, files, credentials, and fleet data |
| `just plan` | Show the planned Hetzner changes |
| `just apply` | Apply the planned Hetzner changes |
| `just output` | Show OpenTofu outputs |
| `just bootstrap devbox-1` | Configure a new host through its first address |
| `just configure devbox-1` | Apply Ansible to one host |
| `just configure-all` | Apply Ansible to each host in sequence |
| `just ping devbox-1` | Check the Ansible connection |
| `just check --limit devbox-1` | Run Ansible in check mode with a diff |
| `just smoke devbox-1` | Run remote health checks |
| `just smoke-all` | Run health checks on all hosts |

### Host settings

Each Hetzner host requires five settings:

| Setting | Effect |
| --- | --- |
| `server_type` | Selects the Hetzner server type. A change resizes the host |
| `location` | Selects the Hetzner location. A change replaces the host |
| `image` | Selects Ubuntu 24.04 or 26.04. A change replaces the host |
| `enable_public_ssh` | Permits bootstrap SSH from the configured IPv4 ranges |
| `delete_protection` | Prevents host deletion and rebuilds |

The file [`fleet/contract.json`](fleet/contract.json) defines valid host names, locations, Ubuntu releases, and documentation address ranges.

### Add a Hetzner host

1. Add the host to `ansible/inventory/hosts.yml`.
2. Add its specification to `fleet/providers/hcloud/devboxes.auto.tfvars.json`.
3. Run `just doctor`.
4. Run `just check-availability <host>`.
5. Run `just plan` and review the result.
6. Run `just apply`.
7. Run `just bootstrap <host>`.

### Add an existing host

Add the host to the Ansible inventory. Then add its first address to `fleet/providers/manual/hosts.yml`:

```yaml
---
devbox-2:
  address: 192.168.1.40
  admin_user: local-admin
```

The `admin_user` value must match `ansible_user` for that host. Run `just doctor`, then run `just bootstrap devbox-2`.

After MagicDNS works, commands reach the host by name. The initial address is not necessary after this point.

### Resize a Hetzner host

Change only `server_type`. Stop active work and take a snapshot. Then review the plan before you apply it.

OpenTofu keeps the current disk size during the resize.

### Remove a Hetzner host

Remove a protected host in two applies:

1. Set `delete_protection` to `false`.
2. Run `just plan`, then run `just apply`.
3. Remove the host from the provider specification and inventory.
4. Run `just plan` again and check that it removes one server and firewall.
5. Run `just apply`.

> [!CAUTION]
> Save all required host data before the second apply. Do not reuse a retired `devbox-N` number.

### Configure Claude keepalive

By default, the playbook does not install the Claude keepalive cron job. Enable it for one host in `ansible/inventory/host_vars/<name>.yml`:

```yaml
---
claude_keepalive_enabled: true
```

Only one host can enable this job. The job sends `hello` every four hours after authentication, and each successful run consumes Claude usage.

## Repository layout

| Path | Purpose |
| --- | --- |
| `ansible/inventory/hosts.yml` | Lists all fleet members |
| `ansible/inventory/host_vars/` | Stores settings for individual hosts |
| `ansible/roles/` | Installs and configures each host feature |
| `fleet/contract.json` | Defines shared fleet rules |
| `fleet/providers/hcloud/` | Creates Hetzner hosts and firewalls |
| `fleet/providers/manual/` | Records hosts created outside this repository |
| `scripts/` | Implements fleet commands and checks |
| `versions.yml` | Pins downloaded runtimes and CLIs |
| `package.json` | Pins npm coding tools |

Each provider contains an executable `hosts.sh`. The script reports the hosts that the provider owns and their first addresses.

## Security

- The Hetzner firewall does not expose application ports.
- Public SSH accepts traffic only from the configured IPv4 ranges.
- Password authentication and root SSH are disabled.
- The agent account has no password and no sudo access.
- OpenTofu state remains local and can contain secrets.
- T3 Code tokens, CLI logins, workspaces, and caches remain on each host.

Restrict your tailnet policy to approved users and hosts. Use scoped repository credentials or deploy keys.

See [SECURITY.md](SECURITY.md) to report a vulnerability.

## Development

Install project dependencies and initialize OpenTofu:

```bash
just init
```

Run the local checks:

```bash
just lint
just test
```

`just test` uses local fixtures and a mocked Hetzner provider. It does not create infrastructure or contact a DevBox.

Install the pre-commit hook:

```bash
just install-hooks
```

Dependabot updates the npm CLI pins in `package.json`. Node.js, mise, GitHub CLI, and Herdr use checksum pins in `versions.yml`.

Before you deploy a pin change, review its release notes and checksums. Then run:

```bash
just check
just configure-all
just smoke-all
```
