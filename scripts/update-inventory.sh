#!/usr/bin/env bash
# Generate the ignored Ansible inventory from OpenTofu outputs.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
inventory="$repo_root/ansible/inventory/hosts.yml"
example="$repo_root/ansible/inventory/hosts.example.yml"

host="${1:-}"
if [ -z "$host" ]; then
	# Prefer the tailnet address so Ansible works on networks that block
	# outbound TCP/22. Falls back to the public IPv4 for fresh provisions,
	# before Tailscale is enrolled.
	set +a
	server_name="${TF_VAR_server_name:-agent-vps}"
	tailnet_host="$(tailscale status --json 2>/dev/null |
		jq -r --arg n "$server_name" \
			'.Peer[].DNSName | select(startswith($n + ".")) | rtrimstr(".")' |
		head -1 || true)"
	if [ -n "$tailnet_host" ]; then
		host="$tailnet_host"
	else
		host="$(tofu -chdir="$repo_root/tofu" output -raw server_ipv4)"
	fi
fi
if ! admin_user="$(tofu -chdir="$repo_root/tofu" output -raw admin_user 2>/dev/null)"; then
	admin_user="${TF_VAR_admin_user:-admin}"
fi

if [[ ! "$host" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]]; then
	echo "Invalid inventory host: $host" >&2
	exit 1
fi
if [[ ! "$admin_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
	echo "Invalid admin user from OpenTofu: $admin_user" >&2
	exit 1
fi

cp "$example" "$inventory"

grep -q '^[[:space:]]*ansible_host:' "$inventory"
grep -q '^[[:space:]]*ansible_user:' "$inventory"

temp_file="$(mktemp "${inventory}.XXXXXX")"
trap 'rm -f "$temp_file"' EXIT

sed \
	-e "s|^\([[:space:]]*ansible_host:\).*|\1 $host|" \
	-e "s|^\([[:space:]]*ansible_user:\).*|\1 $admin_user|" \
	"$inventory" >"$temp_file"
mv "$temp_file" "$inventory"
trap - EXIT

echo "Updated Ansible inventory: $admin_user@$host"
