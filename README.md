# not-cursor-cloud

An opinionated, self-hosted remote coding agent on a Hetzner VPS. It installs
T3 Code, Codex CLI, Claude Code, and OpenCode, then exposes the web interface
privately through Tailscale Serve.

The application never listens on a public interface. Public SSH is restricted
to your current IP during bootstrap and should be removed after Tailscale is
verified.

## What it creates

- One Hetzner Cloud server and firewall, managed by OpenTofu.
- Ubuntu 24.04 with security updates and hardened SSH, managed by Ansible.
- A passwordless, non-sudo `agent` account for coding tools.
- Pinned Node.js, T3 Code, Codex CLI, Claude Code, and OpenCode versions.
- Tailscale SSH and Tailscale Serve; Funnel is never enabled.

Review Hetzner's current pricing before applying. Running this repository
creates paid infrastructure.

## Supported setup

- Hetzner Cloud
- Ubuntu 24.04 LTS
- x86-64 or ARM64 servers
- macOS or Linux as the controller
- A Tailscale account and clients on the devices that need access

## Current limitations

- Workspaces live on the VPS filesystem; automated backups are not implemented.
- Repository workloads are not container-isolated. Do not run untrusted code.
- This is a single-user, single-server setup rather than a hosted service.

## Prerequisites

Install [`tofu`](https://opentofu.org/), [`uv`](https://docs.astral.sh/uv/),
[`just`](https://github.com/casey/just), and `jq` locally. You also need a
Hetzner Cloud project with a read/write API token and an SSH keypair.

On macOS:

```bash
brew install opentofu uv just jq
```

## Quick start

```bash
git clone https://github.com/Reidaa/not-cursor-cloud.git
cd not-cursor-cloud
just setup
```

Edit `.env` and replace every placeholder. In particular, restrict
`TF_VAR_bootstrap_ssh_source_ips` to your current public IPv4 address with a
`/32` suffix. Then run:

```bash
just doctor
just init
just bootstrap
```

`just bootstrap` checks server availability, applies OpenTofu, generates the
local Ansible inventory, waits for cloud-init, and configures the VPS.

## Enroll Tailscale

If `TAILSCALE_AUTHKEY` is empty, enrollment is intentionally manual. Use the
public address printed by OpenTofu:

```bash
ssh admin@$(tofu -chdir=tofu output -raw server_ipv4)
sudo tailscale up --hostname agent-vps --ssh
exit
just configure
```

If you use a different `TF_VAR_admin_user` or `TF_VAR_server_name`, substitute
those values. Alternatively, set a short-lived, pre-authorized Tailscale auth
key in `.env`; revoke it after bootstrap.

Tailscale Serve also requires one-time HTTPS approval for the tailnet. If
`just configure` reports that approval is needed, follow the printed SSH
instructions, open the URL from `tailscale serve`, enable HTTPS, and leave
Funnel disabled. Then run `just configure` again.

Once SSH through the tailnet works, switch Ansible to the MagicDNS hostname:

```bash
just set-inventory-host agent-vps.<your-tailnet>.ts.net
ssh admin@agent-vps.<your-tailnet>.ts.net true
```

Restrict your tailnet policy so only your identity can reach this node. Public
SSH closure is not automated yet; until a safely isolated workflow is designed,
keep `TF_VAR_bootstrap_ssh_source_ips` restricted to your own IPv4 `/32` and
review every OpenTofu plan before applying it.

## Pair a T3 Code client

Generate a pairing credential as the same account that runs the T3 Code
service:

```bash
ssh admin@agent-vps.<your-tailnet>.ts.net
sudo -u agent -H /usr/local/bin/t3 auth pairing create \
  --base-url "https://agent-vps.<your-tailnet>.ts.net" \
  --ttl 10m \
  --label "browser"
```

Substitute the configured admin, server, tailnet, and agent names if you
changed the defaults. The command prints a `Token` and a complete `Pair URL`.
Open the URL once before it expires, or enter these values in **Add
Environment**:

```text
Host: https://agent-vps.<your-tailnet>.ts.net
Pairing code: <the new 12-character Token value>
```

The Host is the HTTPS origin only: do not append `/pair`. You can instead paste
the complete Pair URL into the Host field and let T3 Code extract both values.
Pairing tokens are single-use; generate a different token for every browser,
device, or environment entry. Treat tokens and Pair URLs as passwords.

If all administrative browser sessions are lost, restarting the service issues
a fresh administrative startup token:

```bash
sudo systemctl restart t3code
sudo journalctl -u t3code --since "2 minutes ago" -o cat --no-pager
```

The startup log advertises a localhost URL because T3 Code listens securely on
`127.0.0.1`. Replace only its origin before opening it:

```text
Printed: http://127.0.0.1:3773/pair#token=<token>
Open:    https://agent-vps.<your-tailnet>.ts.net/pair#token=<token>
```

Open the rewritten URL once within five minutes. Do not reuse its token in
**Add Environment** after the browser has consumed it.

## Authenticate the agent CLIs

Authentication is interactive and is not stored in infrastructure state:

```bash
ssh admin@agent-vps.<your-tailnet>.ts.net
sudo -iu agent
codex login --device-auth
claude auth login
opencode auth login
```

Substitute the configured `AGENT_USER` if you changed the default.

Once Claude Code is authenticated, cron sends the non-persistent prompt `hello`
every four hours. Before authentication, each scheduled run exits without
making a request. The scheduled invocation disables project customizations and
tools, and each successful run consumes Claude usage. Inspect the managed
crontab and cron activity with:

```bash
sudo crontab -u agent -l
sudo journalctl -u cron
```

Use `mise use -g` for tools that should be available to every agent session.
`mise install` downloads tools but does not select a version for the shims:

```bash
mise use -g uv just
```

## Authenticate GitHub

The GitHub CLI is installed, but authentication and Git commit identity are
user-specific and must be configured interactively as the `agent` user:

```bash
ssh admin@agent-vps.<your-tailnet>.ts.net
sudo -iu agent
git config --global user.name "Your Name"
git config --global user.email "your-github-email@example.com"
gh auth login --web --git-protocol https
gh auth setup-git
gh auth status
```

The selected GitHub account or token needs write access to repositories the
agent should push to. Authentication is stored in the restricted agent home
directory and is not managed by Ansible or infrastructure state.

## Verify

```bash
just smoke admin@agent-vps.<your-tailnet>.ts.net
```

Then open `https://agent-vps.<your-tailnet>.ts.net` on a device connected to
your tailnet.

## Configuration

`just setup` creates two ignored local files and never overwrites them:

| File | Purpose |
| --- | --- |
| `.env` | Hetzner credentials, SSH key, server settings, and optional Tailscale key |
| `ansible/inventory/hosts.yml` | Current Ansible SSH target, generated from OpenTofu |

Tracked examples document every setting. Application and runtime version pins
live in [`versions.yml`](versions.yml).

Useful commands:

```bash
just                 # list commands
just plan            # preview infrastructure changes
just update-inventory # restore the public-IP bootstrap target from OpenTofu
just check            # Ansible dry run
just lint             # run repository checks
just destroy          # permanently destroy the VPS
```

## Security and state

- `.env`, generated inventory, OpenTofu state, and plan files must never be
  committed.
- `just setup` restricts local configuration and state files to your account.
- Local OpenTofu state is plaintext and must be treated as sensitive. Teams
  should use an access-controlled, encrypted remote backend.
- The configured agent account has no password and no sudo access.
- No application port is opened by the Hetzner firewall.
- Repository credentials should use scoped tokens or deploy keys.

See [SECURITY.md](SECURITY.md) for vulnerability reporting.

## Updates and removal

Review upstream release notes before changing [`versions.yml`](versions.yml),
then run `just check`, `just configure`, and the smoke test.

`just destroy` deletes the VPS and its local storage. Back up any workspaces
before using it. The longer-term design is documented in
[`docs/t3code-vps-implementation-plan.md`](docs/t3code-vps-implementation-plan.md).
