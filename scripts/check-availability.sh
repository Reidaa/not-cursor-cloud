#!/usr/bin/env bash
# Check stock for one Hetzner host selected through inventory.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/fleet.sh
source "$repo_root/scripts/lib/fleet.sh"

wait_mode=false
if [ "${1:-}" = "--wait" ]; then
	wait_mode=true
	shift
fi

fleet_require_machine "check-availability.sh [--wait] devbox-N" "$@"
machine="$fleet_machine"

if [ "$fleet_group" != "hcloud_devboxes" ]; then
	echo "$machine belongs to manual_devboxes; Hetzner has no stock to check" >&2
	exit 1
fi

server_type="$(fleet_host_var "$fleet_inventory_json" "$machine" hcloud_server_type)"
location="$(fleet_host_var "$fleet_inventory_json" "$machine" hcloud_location)"
token="${TF_VAR_hcloud_token:?TF_VAR_hcloud_token is not set (put it in .env)}"
poll_seconds="${POLL_SECONDS:-60}"

command -v jq >/dev/null || {
	echo "jq is required" >&2
	exit 1
}

api() {
	curl -fsS -H "Authorization: Bearer $token" "https://api.hetzner.cloud/v1/$1"
}

type_id="$(api "server_types?name=$server_type" | jq -er '.server_types[0].id')" || {
	echo "Unknown server type: $server_type" >&2
	exit 1
}

while true; do
	available_locations="$(api "datacenters?per_page=50" |
		jq -r --argjson id "$type_id" \
			'.datacenters[] | select(.server_types.available | index($id)) | .location.name' |
		sort -u)"

	if grep -qx "$location" <<<"$available_locations"; then
		echo "OK: $server_type is available in $location for $machine"
		exit 0
	fi

	echo "UNAVAILABLE: $server_type in $location for $machine" >&2
	if [ -n "$available_locations" ]; then
		echo "Currently in stock in: $(tr '\n' ' ' <<<"$available_locations")" >&2
	else
		echo "$server_type is sold out in every location right now." >&2
	fi

	$wait_mode || exit 1
	echo "Retrying in ${poll_seconds}s (Ctrl-C to stop)..." >&2
	sleep "$poll_seconds"
done
