#!/usr/bin/env bash
# Preflight: verify the Hetzner server type is in stock in the target
# location before tofu apply. CX plans regularly sell out per-location;
# this fails fast (or waits with --wait) instead of failing mid-apply.
# Usage: check-availability.sh [--wait] [server_type] [location]
# Defaults follow the tofu variables; TF_VAR_* overrides from .env apply.
set -euo pipefail

wait_mode=false
if [ "${1:-}" = "--wait" ]; then
	wait_mode=true
	shift
fi

server_type="${1:-${TF_VAR_server_type:-cx33}}"
location="${2:-${TF_VAR_location:-nbg1}}"
token="${TF_VAR_hcloud_token:?TF_VAR_hcloud_token is not set (put it in .env)}"
poll_seconds="${POLL_SECONDS:-60}"

command -v jq >/dev/null || {
	echo "jq is required (brew install jq)" >&2
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
	# Availability is reported per datacenter; each location has one today.
	available_locations="$(api "datacenters?per_page=50" |
		jq -r --argjson id "$type_id" \
			'.datacenters[] | select(.server_types.available | index($id)) | .location.name' |
		sort -u)"

	if grep -qx "$location" <<<"$available_locations"; then
		echo "OK: $server_type is available in $location"
		exit 0
	fi

	echo "UNAVAILABLE: $server_type in $location" >&2
	if [ -n "$available_locations" ]; then
		echo "Currently in stock in: $(tr '\n' ' ' <<<"$available_locations")" >&2
		echo "Either wait, or re-run with TF_VAR_location=<loc>." >&2
	else
		echo "$server_type is sold out in every location right now." >&2
	fi

	$wait_mode || exit 1
	echo "Retrying in ${poll_seconds}s (Ctrl-C to stop)..." >&2
	sleep "$poll_seconds"
done
