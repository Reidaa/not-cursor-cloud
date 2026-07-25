#!/usr/bin/env bash
# Configure one new DevBox through its first reachable address.
set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/fleet.sh
source "$repo_root/scripts/lib/fleet.sh"

fleet_require_machine "bootstrap.sh devbox-N" "$@"
machine="$fleet_machine"

"$repo_root/scripts/doctor.sh"

admin_user="$(fleet_host_var "$fleet_inventory_json" "$machine" ansible_user)"

if [ "$fleet_group" = "hcloud_devboxes" ]; then
	devboxes_json="$(tofu -chdir="$repo_root/tofu" output -json devboxes)"
	address="$(jq -er --arg machine "$machine" '.[$machine].ipv4' <<<"$devboxes_json")" || {
		echo "OpenTofu has no public IP for $machine; run just apply first" >&2
		exit 1
	}
else
	address="$(fleet_host_var "$fleet_inventory_json" "$machine" ansible_host)"
fi

echo "Waiting for SSH on $admin_user@$address"
ssh_ready=false
for _ in $(seq 1 60); do
	if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
		"$admin_user@$address" true 2>/dev/null; then
		ssh_ready=true
		break
	fi
	sleep 10
done
if ! $ssh_ready; then
	echo "SSH did not become ready at $admin_user@$address after 10 minutes" >&2
	exit 1
fi

extra_vars="$(jq -nc --arg address "$address" '{ansible_host: $address}')"
echo "Running Ansible for $machine through $address"
cd "$repo_root/ansible"
uv run ansible-playbook playbook.yml \
	--limit "$machine" \
	--extra-vars "$extra_vars"

echo "Done. Check ssh $admin_user@$machine, then run: just configure $machine"
