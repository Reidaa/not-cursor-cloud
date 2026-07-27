#!/usr/bin/env bash
# Print the DevBoxes this provider is responsible for:
#
#   {"devbox-1": {"address": "203.0.113.10", "admin_user": "admin"}}
#
# address is null for a host that is declared but not created yet, so a caller
# can tell "no such host" apart from "not applied yet". Ansible never runs this;
# it exists so local commands can check the fleet against what really exists.
set -euo pipefail

provider_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
specs_file="${FLEET_HCLOUD_SPECS_FILE:-$provider_dir/devboxes.auto.tfvars.json}"

declared='{}'
if [ -f "$specs_file" ]; then
	declared="$(jq -e '.devboxes' "$specs_file")"
fi

# tofu output fails before the first init or apply. That is a fleet whose hosts
# have no address yet, not an error.
created="$(tofu -chdir="$provider_dir" output -json devboxes 2>/dev/null || echo '{}')"

# cloud-init creates TF_VAR_admin_user, so a host that does not exist yet
# reports the account it is going to get.
jq -n \
	--argjson declared "$declared" \
	--argjson created "$created" \
	--arg planned_admin "${TF_VAR_admin_user:-admin}" '
  reduce ($declared | keys[]) as $name ({};
    .[$name] = {
      address: ($created[$name].ipv4 // null),
      admin_user: ($created[$name].admin_user // $planned_admin)
    })'
