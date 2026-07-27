#!/usr/bin/env bash
# Read fleet data through Ansible so every command uses the same view.

fleet_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fleet_inventory_input="${ANSIBLE_INVENTORY_FILE:-$fleet_repo_root/ansible/inventory/hosts.yml}"
if [[ "$fleet_inventory_input" = /* ]]; then
	fleet_inventory_file="$fleet_inventory_input"
else
	fleet_inventory_file="$fleet_repo_root/$fleet_inventory_input"
fi

# The fleet contract — valid names, locations, Ubuntu releases — shared with
# OpenTofu and the Ansible playbook. Read on demand so sourcing this file needs
# no tools.
fleet_contract_file="$fleet_repo_root/fleet/contract.json"

# Each provider ships one script that prints what it has created. Tests point
# this at fixtures so a check never depends on the real fleet.
fleet_providers_dir="${FLEET_PROVIDERS_DIR:-$fleet_repo_root/fleet/providers}"

fleet_contract() {
	jq -er "$1" "$fleet_contract_file"
}

fleet_read_inventory() {
	(
		cd "$fleet_repo_root/ansible" || return
		uv run ansible-inventory -i "$fleet_inventory_file" --list
	)
}

fleet_validate_machine_name() {
	local machine="$1"
	local pattern
	pattern="$(fleet_contract '.machine_name_pattern')"
	if [[ ! "$machine" =~ $pattern ]]; then
		echo "Invalid machine name: $machine" >&2
		return 1
	fi
}

# Every provider prints what it has created, keyed by machine name. Collect them
# into {provider: {machine: {address, admin_user}}} so a caller can see who owns
# a host as well as how to reach it. Ansible never reads this: the contract
# exists to check the fleet, not to build the inventory.
fleet_provider_hosts() {
	local script provider hosts merged='{}'
	for script in "$fleet_providers_dir"/*/hosts.sh; do
		provider="$(basename "$(dirname "$script")")"
		# A provider that cannot answer is a fault, not an empty fleet.
		hosts="$("$script")" || return 1
		merged="$(jq --arg provider "$provider" --argjson hosts "$hosts" \
			'.[$provider] = $hosts' <<<"$merged")" || return 1
	done
	printf '%s\n' "$merged"
}

fleet_host_var() {
	local inventory_json="$1"
	local machine="$2"
	local variable="$3"
	jq -er --arg machine "$machine" --arg variable "$variable" \
		'._meta.hostvars[$machine][$variable] // error("missing host variable")' \
		<<<"$inventory_json"
}

# The same read for variables inventory may leave unset — the caller supplies
# the value to use instead of failing.
fleet_host_var_or() {
	local inventory_json="$1"
	local machine="$2"
	local variable="$3"
	local fallback="$4"
	jq -r --arg machine "$machine" --arg variable "$variable" --arg fallback "$fallback" \
		'._meta.hostvars[$machine][$variable] // $fallback' \
		<<<"$inventory_json"
}

# Every per-host command opens the same way: check the argument count, check the
# name, then confirm the host is in the fleet. Callers pass their usage line and
# their arguments, and read the results from fleet_machine and
# fleet_inventory_json.
fleet_require_machine() {
	local usage="$1"
	shift
	if [ "$#" -ne 1 ] || [ -z "$1" ]; then
		echo "usage: $usage" >&2
		return 1
	fi

	fleet_machine="$1"
	fleet_validate_machine_name "$fleet_machine" || return 1
	fleet_inventory_json="$(fleet_read_inventory)"
	if ! jq -e --arg machine "$fleet_machine" '._meta.hostvars | has($machine)' \
		>/dev/null <<<"$fleet_inventory_json"; then
		echo "Unknown machine: $fleet_machine" >&2
		return 1
	fi
}

fleet_select_hosts() {
	local pattern="$1"
	local output name_pattern line host

	if ! output="$(
		cd "$fleet_repo_root/ansible"
		uv run ansible -i "$fleet_inventory_file" "$pattern" --list-hosts
	)"; then
		return 1
	fi

	# --list-hosts indents each host under a header line; keep the entries that
	# are DevBox names and drop the header.
	name_pattern="$(fleet_contract '.machine_name_pattern')"
	while IFS= read -r line; do
		host="${line//[[:space:]]/}"
		if [ -n "$host" ] && [[ "$host" =~ $name_pattern ]]; then
			printf '%s\n' "$host"
		fi
	done <<<"$output"
}

# Every fleet-wide command opens the same way: check the argument count, then
# resolve the pattern to real hosts so a typo fails here rather than as an
# Ansible run that silently matches nothing. Callers pass their usage line and
# their arguments, and read the results from fleet_pattern and fleet_hosts.
# shellcheck disable=SC2034  # fleet_pattern is read by the sourcing script
fleet_require_hosts() {
	local usage="$1"
	shift
	if [ "$#" -gt 1 ]; then
		echo "usage: $usage" >&2
		return 1
	fi

	local pattern="${1:-devboxes}"
	local selected host

	# Collect the hosts before splitting them, so a failed Ansible run reports
	# its own error instead of an empty match.
	if ! selected="$(fleet_select_hosts "$pattern")"; then
		return 1
	fi

	fleet_hosts=()
	while IFS= read -r host; do
		if [ -n "$host" ]; then
			fleet_hosts+=("$host")
		fi
	done <<<"$selected"

	if [ "${#fleet_hosts[@]}" -eq 0 ]; then
		echo "No hosts match: $pattern" >&2
		return 1
	fi

	fleet_pattern="$pattern"
}
