# not-cursor-cloud

An opinionated fleet of remote coding hosts. Ansible manages all DevBoxes, and
knows only which machines belong to the fleet. Each provider under
`fleet/providers/` decides how its own machines are made: OpenTofu creates the
Hetzner ones, and you may also add machines you built by hand.

Each host runs T3 Code, Codex CLI, Claude Code, and OpenCode. Apps stay
private through Tailscale.

## What it creates

- One server and firewall for each host in the Hetzner DevBox specs.
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
`/32` suffix. Then name your hosts in two places before you plan: list them in
`ansible/inventory/hosts.yml`, and give the Hetzner ones a specification in
`fleet/providers/hcloud/devboxes.auto.tfvars.json`. Host names must use
`devbox-N`. `just doctor` refuses a host that appears in one file but not the
other.

```bash
just doctor
just init
just check-availability devbox-1
just plan
just apply
just bootstrap devbox-1
```

`just setup` never replaces an existing inventory. No command writes inventory.
`just bootstrap` asks each provider for the new host's address, waits for SSH,
and runs Ansible for that host. Every later command reaches the host by its own
name, because the tailscale role enrols it under its inventory name.

## Enroll Tailscale

If `TAILSCALE_AUTHKEY` is empty, enrollment is intentionally manual. Use the
public address from the fleet output:

```bash
ssh admin@$(tofu -chdir=fleet/providers/hcloud output -json devboxes | jq -r '."devbox-1".ipv4')
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
SSH is set per host in the Hetzner specs. After MagicDNS works, set that host's
`enable_public_ssh` to `false`, then review and apply that one firewall change.

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

The fleet is split in two. Ansible knows which machines are members and what
should run on them. It knows nothing about who created them or where they are;
that belongs to the provider that made them.

| File | Purpose |
| --- | --- |
| `ansible/inventory/hosts.yml` | Fleet membership: one flat list of names |
| `ansible/inventory/host_vars/<name>.yml` | One host's application settings |
| `fleet/providers/hcloud/devboxes.auto.tfvars.json` | What each Hetzner machine costs and where it runs |
| `fleet/providers/manual/hosts.yml` | Machines you made, and the address each needs for its first run |
| `.env` | Fleet secrets, bootstrap ranges, account defaults, and an optional Tailscale key |

`just setup` creates all four local files from tracked examples and never
overwrites them. A host needs no address after its first run: the tailscale role
enrols it under its inventory name, so the name is the address.

Each Hetzner machine takes five settings, and all five are required:

| Setting | Meaning |
| --- | --- |
| `server_type` | Hetzner server type, such as `cx33`. Changing it resizes the machine |
| `location` | Hetzner location. Changing it replaces the machine |
| `image` | `ubuntu-24.04` or `ubuntu-26.04`. Changing it replaces the machine |
| `enable_public_ssh` | Whether the firewall opens SSH to your bootstrap ranges |
| `delete_protection` | Whether Hetzner refuses to delete or rebuild the machine |

[`fleet/contract.json`](fleet/contract.json) holds the rules every host must
follow: the machine name pattern, the server type pattern, the accepted Hetzner
locations, the supported Ubuntu releases, and the documentation IPv4 ranges that
mark an unedited example. OpenTofu, `just doctor`, and the Ansible playbook all
read it, so adding a location or a release means editing one file.

Each rule has exactly one owner. Hetzner spec rules belong to OpenTofu, which
refuses a bad host even when nobody ran `just doctor`. Rules about the fleet as
a whole belong to `scripts/validate-fleet.py`. The three values that live in
both layers — membership, the admin account, and which provider owns a host —
belong to `just doctor`, the only command that reads both.

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

`just test` runs the offline checks: fleet fixtures, fleet command behaviour,
the Tailscale role against both Ubuntu releases, the tailnet rename decision,
and the OpenTofu plan against a mocked Hetzner provider. It creates nothing and
contacts no host, so it is safe to run at any time.

`just destroy-hcloud-fleet` deletes every declared Hetzner host at once. Use the
two-apply removal below instead; the recipe exists for tearing down a whole
throwaway fleet.

## Manage the fleet

To add a Hetzner host, choose a new `devbox-N` number, add it to the inventory,
and give it a specification in `fleet/providers/hcloud/devboxes.auto.tfvars.json`.
Run `doctor`, check stock, plan, apply, then bootstrap that host. Adding one
entry should add one server and one firewall.

To add a host that you made, add its name to the inventory and an entry in
`fleet/providers/manual/hosts.yml` giving the address that works for its first
run. Run `doctor`, then bootstrap it. Hand-made hosts must not change the
OpenTofu plan.

To resize a Hetzner host, change only its `server_type`. Stop active work, take
a snapshot, shut down the host, and check that the plan shows one in-place
change. OpenTofu keeps the current disk size.

Remove a Hetzner host in two applies. First set its `delete_protection` to
`false` and apply only that change. Then drop it from both the specs and the
inventory, check that the next plan deletes one server and firewall, and apply.
Save any data first and retire the host number. Do not reuse it.

A fleet still holding the original `agent-vps` names has one rename left. Back
up OpenTofu state, then check that the plan moves state and updates names in
place. It must show no add, delete, disk growth, IP change, or replacement.
Apply only after that check, then test `ssh admin@devbox-1`.

## Add a provider

A provider is one directory under `fleet/providers/` holding one executable
`hosts.sh`, which prints what that provider has created:

```json
{ "devbox-4": { "address": "203.0.113.10", "admin_user": "admin" } }
```

`address` is `null` for a machine that is declared but does not exist yet.
`just bootstrap` uses the address to reach a new host once, before it joins the
tailnet; `just doctor` uses the names and accounts to check the fleet against
the inventory. Ansible never runs these scripts, and nothing under `ansible/`
changes when a provider is added.

## Security and state

- Never commit `.env`, the Hetzner specs, the hand-made host list, OpenTofu
  state, or plan files. The inventory holds only names and is tracked-example
  safe, but the real one stays ignored too.
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
