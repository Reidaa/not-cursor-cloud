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

# A new host has not joined the tailnet yet, so its name does not resolve. Its
# provider is the only thing that knows an address for this one run; take the
# first provider that claims the host.
address="$(fleet_provider_hosts |
	jq -er --arg machine "$machine" \
		'[.[][$machine].address // empty] | first // error("no address")')" || {
	echo "No provider has an address for $machine; create it first" >&2
	exit 1
}

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
