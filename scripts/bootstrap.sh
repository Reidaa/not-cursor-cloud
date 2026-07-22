#!/usr/bin/env bash
# One-shot bootstrap: provision the VPS then configure it
# (Steps 2-5). Requires: tofu, uv, TF_VAR_hcloud_token set, and
# TF_VAR_ssh_public_key set (or a .env file — run via `just bootstrap`).
set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$repo_root/scripts/doctor.sh"

echo "==> Preflight: server type availability"
"$repo_root/scripts/check-availability.sh"

echo "==> Provisioning (tofu apply)"
tofu -chdir="$repo_root/tofu" init -input=false
tofu -chdir="$repo_root/tofu" apply

ip="$(tofu -chdir="$repo_root/tofu" output -raw server_ipv4)"
admin_user="$(tofu -chdir="$repo_root/tofu" output -raw admin_user)"
"$repo_root/scripts/update-inventory.sh"

echo "==> Waiting for SSH (cloud-init may reboot the host once)"
ssh_ready=false
for _ in $(seq 1 60); do
	if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
		"$admin_user@$ip" true 2>/dev/null; then
		ssh_ready=true
		break
	fi
	sleep 10
done
if ! $ssh_ready; then
	echo "SSH did not become ready at $admin_user@$ip after 10 minutes" >&2
	exit 1
fi

echo "==> Running Ansible against $admin_user@$ip"
cd "$repo_root/ansible"
uv run ansible-playbook playbook.yml "$@"

echo "==> Done. Next: enroll Tailscale if needed, switch the inventory to"
echo "    MagicDNS, and verify access. Public SSH closure is not automated yet."
