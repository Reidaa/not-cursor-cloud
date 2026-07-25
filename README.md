# not-cursor-cloud

An opinionated fleet of remote coding hosts. Ansible manages all DevBoxes.
OpenTofu creates the hosts listed in the `hcloud_devboxes` inventory group.
You may also add machines that you create by hand.

Each host runs T3 Code, Codex CLI, Claude Code, and OpenCode. Apps stay
private through Tailscale.

## What it creates

- One server and firewall for each host in `hcloud_devboxes`.
- Ubuntu 24.04 or 26.04 with security updates and hardened SSH.
- A passwordless, non-sudo `agent` account for coding tools.
- Pinned Node.js, mise, GitHub CLI, T3 Code, Codex CLI, Claude Code, and
  OpenCode versions.
- Tailscale SSH and a private HTTPS route for T3 Code; Funnel is never enabled.

Review Hetzner's current pricing before applying. Running this repository
creates paid infrastructure.

## Supported (Tested) setup

- Hetzner Cloud
- Ubuntu 24.04 or 26.04 LTS
- x86-64 or ARM64 servers
- macOS as the controller
- A Tailscale account and clients on the devices that need access

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

Edit `.env` and replace every placeholder. Restrict
`TF_VAR_bootstrap_ssh_source_ips` to your current public IPv4 address with a
`/32` suffix. Edit `ansible/inventory/hosts.yml` before you plan. Host names
must use `devbox-N`, and OpenTofu reads only `hcloud_devboxes`.

```bash
just doctor
just init
just check-availability devbox-1
just plan
just apply
just bootstrap devbox-1
```

`just setup` never replaces an existing inventory. No command writes inventory.
`just bootstrap` reads the new public IP from OpenTofu, waits for SSH, and runs
Ansible for that host.

## Enroll Tailscale

If `TAILSCALE_AUTHKEY` is empty, enrollment is intentionally manual. Use the
public address from the fleet output:

```bash
ssh admin@$(tofu -chdir=tofu output -json devboxes | jq -r '."devbox-1".ipv4')
sudo tailscale up --hostname devbox-1 --ssh
exit
ssh admin@devbox-1 true
just configure devbox-1
```

You can instead set a short-lived Tailscale auth key in `.env`. Revoke it after
bootstrap.

Tailscale Serve also needs one-time HTTPS approval for the tailnet. If
`just configure devbox-1` says Tailscale needs approval, follow the SSH steps,
open the URL from `tailscale serve`, enable HTTPS, and leave Funnel off. Then
run `just configure devbox-1` again.

Restrict your tailnet policy so only your identity can reach this node. Public
SSH is set per host in inventory. After MagicDNS works, set
`hcloud_enable_public_ssh: false`, then review and apply that one firewall
change.

## Pair a T3 Code client

Generate a pairing credential as the same account that runs the T3 Code
service:

```bash
ssh admin@devbox-1.<your-tailnet>.ts.net
sudo -u agent -H /usr/local/bin/t3 auth pairing create \
  --base-url "https://devbox-1.<your-tailnet>.ts.net" \
  --ttl 10m \
  --label "browser"
```

Substitute the configured admin, server, tailnet, and agent names if you
changed the defaults. The command prints a `Token` and a complete `Pair URL`.
Open the URL once before it expires, or enter these values in **Add
Environment**:

```text
Host: https://devbox-1.<your-tailnet>.ts.net
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
Open:    https://devbox-1.<your-tailnet>.ts.net/pair#token=<token>
```

Open the rewritten URL once within five minutes. Do not reuse its token in
**Add Environment** after the browser has consumed it.

## Authenticate the agent CLIs

Authentication is interactive and is not stored in infrastructure state:

```bash
ssh admin@devbox-1.<your-tailnet>.ts.net
sudo -iu agent
codex login --device-auth
claude auth login
opencode auth login
```

Substitute the configured `AGENT_USER` if you changed the default.

## Run the CLIs without prompts

Each CLI role adds an alias to the agent's `.bashrc` that skips the permission
prompts. The DevBox is the sandbox: the agent user has no sudo and nothing
outside its own home to reach, so the CLIs may work unattended inside it.

| Alias | Runs |
| --- | --- |
| `claude-yolo` | `claude --dangerously-skip-permissions` |
| `codex-yolo` | `codex --dangerously-bypass-approvals-and-sandbox` |
| `opencode-yolo` | `opencode --auto` |

The plain `claude`, `codex`, and `opencode` commands still prompt. Override an
alias name or its flags with the `*_alias` and `*_alias_flags` variables in each
role's defaults.

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
ssh admin@devbox-1.<your-tailnet>.ts.net
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
just smoke devbox-1
just smoke-all
```

Then open `https://devbox-1.<your-tailnet>.ts.net` on a device connected to
your tailnet.

## Configuration

`just setup` creates two ignored local files and never overwrites them:

| File | Purpose |
| --- | --- |
| `.env` | Fleet secrets, bootstrap ranges, account defaults, and an optional Tailscale key |
| `ansible/inventory/hosts.yml` | Fleet members and each host's non-secret settings |

[`fleet-contract.json`](fleet-contract.json) holds the rules every host must
follow: the machine name pattern, the server type pattern, the accepted Hetzner
locations, the supported Ubuntu releases, and the documentation IPv4 ranges that
mark an unedited example. OpenTofu, `just doctor`, and the Ansible playbook all
read it, so adding a location or a release means editing one file.

Each of the three still checks the inventory itself, because each can run on its
own: `tofu plan` must refuse a bad host even when nobody ran `just doctor`.

Tracked examples document every setting. Node.js, mise, and GitHub CLI pins
live in [`versions.yml`](versions.yml). Dedicated Ansible roles manage their
checksum-verified releases. Each npm CLI also has its own role: `claude_code`
(which owns the Claude cron job), `codex`, `opencode`, and `t3code`. They share
the `npm_cli` role, which installs one package at the version pinned in
[`package.json`](package.json), and the `bash_alias` role, which defines one
alias in the agent's `.bashrc`. Dependabot checks `package.json` weekly.

Useful commands:

```bash
just doctor
just check-availability devbox-2
just plan
just apply
just bootstrap devbox-2
just configure devbox-2
just configure-all
just smoke devbox-2
just smoke-all
```

`just test` runs the offline checks: inventory fixtures, fleet command
behaviour, the Tailscale role against both Ubuntu releases, the tailnet rename
decision, and the OpenTofu plan against a mocked Hetzner provider. It creates
nothing and contacts no host, so it is safe to run at any time.

`just destroy-hcloud-fleet` deletes every Hetzner host in inventory at once.
Use the two-apply removal below instead; the recipe exists for tearing down a
whole throwaway fleet.

## Manage the fleet

To add a Hetzner host, choose a new `devbox-N` number and add it under
`hcloud_devboxes`. Set its type, location, Ubuntu image, public SSH state, and
delete protection state. Run `doctor`, check stock, plan, apply, then bootstrap
that host. Adding one entry should add one server and one firewall.

To add a host that you made, add it under `manual_devboxes` with an address that
works for its first run. Run `doctor`, then bootstrap it. Manual hosts must not
change the OpenTofu plan.

To resize a Hetzner host, change only `hcloud_server_type`. Stop active work,
take a snapshot, shut down the host, and check that the plan shows one in-place
change. OpenTofu keeps the current disk size.

For the first `devbox-1` move, keep the old Tailscale address in inventory.
Back up OpenTofu state, then check that the plan moves state and updates names
in place. It must show no add, delete, disk growth, IP change, or replacement.
Apply only after that check. Run Ansible through the old address, test
`ssh admin@devbox-1`, then remove `ansible_host`.

Remove a Hetzner host in two applies. First set
`hcloud_delete_protection: false` and apply only that change. Then remove the
inventory entry, check that the next plan deletes one server and firewall, and
apply. Save any data first and retire the host number. Do not reuse it.

## Security and state

- Never commit `.env`, real inventory, OpenTofu state, or plan files.
- `just setup` restricts local configuration and state files to your account.
- Local OpenTofu state is plaintext and must be treated as sensitive. Teams
  should use an access-controlled, encrypted remote backend.
- The configured agent account has no password and no sudo access.
- No application port is opened by the Hetzner firewall.
- Repository credentials should use scoped tokens or deploy keys.
- CLI logins, T3 Code pairs, workspaces, and caches stay on each host.

See [SECURITY.md](SECURITY.md) for vulnerability reporting.

## Updates

Dependabot opens weekly pull requests for the exact npm CLI versions in
[`package.json`](package.json). Ansible reads that file directly, so there is no
generated version file to keep synchronized.

Node.js, mise, and GitHub CLI remain deliberate, checksum-verified pins in
[`versions.yml`](versions.yml). Review upstream release notes and checksums
before changing any version, then run `just check`, `just configure-all`, and
`just smoke-all`.
