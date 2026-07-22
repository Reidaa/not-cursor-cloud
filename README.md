# not-cursor-cloud

An opinionated, self-hosted remote coding agent on a Hetzner VPS. It installs
T3 Code, CLIProxyAPI, Herdr, Codex CLI, Claude Code, and OpenCode. T3 Code and
CLIProxyAPI are private through Tailscale Serve; Herdr connects on demand
through Tailscale SSH without exposing an application port.

The application never listens on a public interface. Public SSH is restricted
to your current IP during bootstrap and should be removed after Tailscale is
verified.

## What it creates

- One Hetzner Cloud server and firewall, managed by OpenTofu.
- Ubuntu 24.04 with security updates and hardened SSH, managed by Ansible.
- A passwordless, non-sudo `agent` account for coding tools.
- Pinned Node.js, mise, GitHub CLI, T3 Code, CLIProxyAPI, Herdr, Codex CLI, Claude Code, and OpenCode versions.
- Tailscale SSH and private HTTPS routes for T3 Code and CLIProxyAPI; Funnel is never enabled.

Review Hetzner's current pricing before applying. Running this repository
creates paid infrastructure.

## Supported (Tested) setup

- Hetzner Cloud
- Ubuntu 24.04 LTS
- x86-64 or ARM64 servers
- macOS as the controller
- A Tailscale account and clients on the devices that need access

## Current limitations

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

Edit `.env` and replace every placeholder. Set the CLIProxyAPI client key and
management bcrypt verifier as described below, and restrict
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

## Use CLIProxyAPI from your laptop

CLIProxyAPI listens on the DevBox loopback interface. Tailscale Serve exposes a
separate private HTTPS listener without changing T3 Code's port 443 route:

```text
https://agent-vps.<your-tailnet>.ts.net:8317/v1
```

Only devices allowed by your tailnet policy can reach this address. Port 8317 is
not open in the Hetzner firewall, and Funnel is disabled. Clients must also send
the key from `CLIPROXYAPI_API_KEY`:

```bash
curl --fail --silent --show-error \
  --header "Authorization: Bearer <client-key>" \
  https://agent-vps.<your-tailnet>.ts.net:8317/v1/models
```

### Use the management panel

The panel uses a separate management key. Generate a random plaintext key and
save it in a password manager:

```bash
openssl rand -hex 32
```

Create its bcrypt verifier without putting the plaintext in shell history:

```bash
uv run --with bcrypt python -c \
  'import bcrypt, getpass; print(bcrypt.hashpw(getpass.getpass("Management key: ").encode(), bcrypt.gensalt()).decode())'
```

Paste the plaintext key at the prompt, then put only the printed verifier in
`.env`. Use single quotes so the dollar signs remain literal:

```dotenv
CLIPROXYAPI_MANAGEMENT_KEY_BCRYPT='$2b$12$replace-with-the-complete-verifier'
```

Open the panel from a device allowed by your tailnet policy:

```text
https://agent-vps.<your-tailnet>.ts.net:8317/management.html
```

Log in with the plaintext key from the password manager, not the bcrypt verifier
or `CLIPROXYAPI_API_KEY`. Tailscale Serve forwards the laptop address, so the
role permits remote management requests. The service still listens only on
`127.0.0.1`, Tailscale controls network access, Funnel stays off, and every
management request requires the separate key.

Ansible installs a pinned, checksum-verified panel and keeps both the panel and
CLIProxyAPI config read-only to the service. Change managed settings or panel
versions in this repository, then rerun `just configure`; panel config edits are
not authoritative.

Provider OAuth credentials belong to the unprivileged `agent` account and stay
in `~agent/.cli-proxy-api`; Ansible does not replace or remove them. For example,
Claude login on the remote server needs an SSH tunnel for its local callback.
Open the tunnel from your laptop:

```bash
ssh -L 54545:127.0.0.1:54545 admin@agent-vps.<your-tailnet>.ts.net
```

Then run the login in that remote session and open the printed URL on your
laptop:

```bash
sudo -iu agent
cli-proxy-api --config ~/.config/cli-proxy-api/config.yaml \
  --claude-login --no-browser
```

Other providers use their own login flag and callback port; follow the
[CLIProxyAPI provider guides](https://help.router-for.me/configuration/provider/claude-code)
when adding them.

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

mise is installed from the exact checksum-verified release in `versions.yml`.
Use `mise use -g` for tools that should be available to every agent session.
`mise install` downloads tools but does not select a version for the shims:

```bash
mise use -g uv just
```

## Authenticate GitHub

The GitHub CLI is installed from the exact checksum-verified GitHub release in
`versions.yml`. Authentication and Git commit identity are user-specific and
must be configured interactively as the `agent` user:

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

## Connect with Herdr

Herdr runs on demand as the unprivileged `agent` account. The local client uses
SSH to start or join the agent-owned server and carries the interface over that
connection.

Install the matching client locally.

Keep the local and remote versions aligned when upgrading. If they differ,
Herdr may offer to place an unmanaged matching binary in
`~agent/.local/bin/herdr`; update the repository pin and local package instead.

First confirm that your tailnet policy permits your identity to use Tailscale
SSH as the non-root `agent` account:

```bash
ssh agent@agent-vps.<your-tailnet>.ts.net true
```

This access is authorized by Tailscale SSH, not the agent's OpenSSH keys. If the
command is denied, add a narrowly scoped Tailscale SSH policy rule for your
identity, this node, and the `agent` user. Conventional OpenSSH remains
admin-only.

Connect directly with a named Herdr session:

```bash
herdr --remote ssh://agent@agent-vps.<your-tailnet>.ts.net --session agents
```

New panes default to `/srv/agent/workspaces`, and Herdr-managed worktrees live
under `/srv/agent/workspaces/worktrees`. Detach with `Ctrl+B`, then `Q`; the
remote panes continue running. Run the same command to reconnect.

For a shorter target, add an alias to `~/.ssh/config`:

```sshconfig
Host agent-vps-herdr
  HostName agent-vps.<your-tailnet>.ts.net
  User agent
  ServerAliveInterval 30
  ServerAliveCountMax 3
```

Then connect with:

```bash
herdr --remote agent-vps-herdr --session agents
```

## Verify

```bash
just smoke admin@agent-vps.<your-tailnet>.ts.net
ssh agent@agent-vps.<your-tailnet>.ts.net herdr --version
```

Then open `https://agent-vps.<your-tailnet>.ts.net` on a device connected to
your tailnet, or attach with the Herdr command above.

## Configuration

`just setup` creates two ignored local files and never overwrites them:

| File | Purpose |
| --- | --- |
| `.env` | Hetzner credentials, CLIProxyAPI client key and management verifier, SSH key, server settings, and optional Tailscale key |
| `ansible/inventory/hosts.yml` | Current Ansible SSH target, generated from OpenTofu |

Tracked examples document every setting. Node.js, mise, GitHub CLI, Herdr,
CLIProxyAPI, and its management panel pins live in
[`versions.yml`](versions.yml). Their checksum-verified releases are managed by
dedicated Ansible roles; `agent_clis` manages the
`package.json`-driven npm CLIs and Claude cron job. Exact npm CLI versions live in
[`package.json`](package.json), which Dependabot checks weekly.

Useful commands:

```bash
just                 # list commands
just plan            # preview infrastructure changes
just update-inventory # refresh the Ansible target (tailnet address, public IP before Tailscale enrollment)
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

## Updates

Dependabot opens weekly pull requests for the exact npm CLI versions in
[`package.json`](package.json). Ansible reads that file directly, so there is no
generated version file to keep synchronized.

Node.js, mise, GitHub CLI, Herdr, CLIProxyAPI, and its management panel remain
deliberate, checksum-verified pins in [`versions.yml`](versions.yml). Review
upstream release notes and checksums before changing any version, then run `just check`,
`just configure`, and the smoke test. Upgrade the local Herdr client to the same
pinned release before the next remote attach.
