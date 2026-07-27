#!/usr/bin/env bash
# Check Hetzner stock for one declared DevBox. The type and location must come
# from the specs rather than from state, because the point of this check is to
# ask whether a machine that does not exist yet can be created.
set -euo pipefail

provider_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
specs_file="${FLEET_HCLOUD_SPECS_FILE:-$provider_dir/devboxes.auto.tfvars.json}"

wait_mode=false
if [ "${1:-}" = "--wait" ]; then
	wait_mode=true
	shift
fi

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
	echo "usage: check-availability.sh [--wait] devbox-N" >&2
	exit 1
fi
machine="$1"

command -v jq >/dev/null || {
	echo "jq is required" >&2
	exit 1
}

if [ ! -f "$specs_file" ]; then
	echo "missing $specs_file; copy devboxes.example.tfvars.json and edit it" >&2
	exit 1
fi

spec="$(jq -e --arg machine "$machine" '.devboxes[$machine]' "$specs_file")" || {
	echo "$machine has no Hetzner spec; there is no stock to check for it" >&2
	exit 1
}

server_type="$(jq -er '.server_type' <<<"$spec")"
location="$(jq -er '.location' <<<"$spec")"
token="${TF_VAR_hcloud_token:?TF_VAR_hcloud_token is not set (put it in .env)}"
poll_seconds="${POLL_SECONDS:-60}"

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
