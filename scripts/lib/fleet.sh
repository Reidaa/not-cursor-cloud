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
fleet_contract_file="$fleet_repo_root/fleet-contract.json"

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

fleet_host_group() {
	local inventory_json="$1"
	local machine="$2"
	jq -er --arg machine "$machine" '
    if (.hcloud_devboxes.hosts // []) | index($machine) then
      "hcloud_devboxes"
    elif (.manual_devboxes.hosts // []) | index($machine) then
      "manual_devboxes"
    else
      error("unknown host")
    end
  ' <<<"$inventory_json"
}

fleet_host_var() {
	local inventory_json="$1"
	local machine="$2"
	local variable="$3"
	jq -er --arg machine "$machine" --arg variable "$variable" \
		'._meta.hostvars[$machine][$variable] // error("missing host variable")' \
		<<<"$inventory_json"
}

# Every per-host command opens the same way: check the argument count, check the
# name, then find the host in inventory. Callers pass their usage line and their
# arguments, and read the results from fleet_machine, fleet_inventory_json, and
# fleet_group.
# shellcheck disable=SC2034  # fleet_group is read by the sourcing script
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
	if ! fleet_group="$(fleet_host_group "$fleet_inventory_json" "$fleet_machine")"; then
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
