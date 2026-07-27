#!/usr/bin/env bash
# Validate local tools and configuration before creating paid infrastructure.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/fleet.sh
source "$repo_root/scripts/lib/fleet.sh"
fail=0

problem() {
	echo "ERROR: $*" >&2
	fail=1
}

for command in tofu uv just jq curl ssh ssh-keygen; do
	command -v "$command" >/dev/null || problem "missing command: $command"
done

inventory_file="$fleet_inventory_file"
if [ ! -f "$inventory_file" ]; then
	problem "missing inventory; run 'just setup' and edit ansible/inventory/hosts.yml"
fi

# The inventory holds only names, but these files hold addresses and the shape
# of the fleet, so they stay readable by their owner alone.
for private_file in "$repo_root/fleet/providers/hcloud/devboxes.auto.tfvars.json" \
	"$repo_root/fleet/providers/manual/hosts.yml"; do
	if [ -f "$private_file" ] &&
		[ "$(stat -f '%Lp' "$private_file" 2>/dev/null || stat -c '%a' "$private_file")" != "600" ]; then
		problem "${private_file#"$repo_root/"} mode must be 0600"
	fi
done

env_file="${FLEET_ENV_FILE:-$repo_root/.env}"
if [ ! -f "$env_file" ]; then
	problem "missing .env; run 'just setup' and fill in the placeholders"
fi

if [ -z "${TF_VAR_hcloud_token:-}" ]; then
	problem "TF_VAR_hcloud_token is empty"
fi

if [[ "${TF_VAR_hcloud_token:-}" =~ [Rr][Ee][Pp][Ll][Aa][Cc][Ee] ]] ||
	[[ "${TF_VAR_hcloud_token:-}" =~ [Pp][Ll][Aa][Cc][Ee][Hh][Oo][Ll][Dd][Ee][Rr] ]]; then
	problem "TF_VAR_hcloud_token still contains a placeholder"
fi

if [ -z "${TF_VAR_ssh_public_key:-}" ]; then
	problem "TF_VAR_ssh_public_key is empty"
elif command -v ssh-keygen >/dev/null &&
	! printf '%s\n' "$TF_VAR_ssh_public_key" | ssh-keygen -l -f - >/dev/null 2>&1; then
	problem "TF_VAR_ssh_public_key is not a valid SSH public key"
fi

source_ips="${TF_VAR_bootstrap_ssh_source_ips:-}"
if [ -z "$source_ips" ]; then
	problem "TF_VAR_bootstrap_ssh_source_ips is empty"
elif command -v jq >/dev/null; then
	if ! jq -e 'type == "array" and length > 0 and all(.[]; type == "string")' \
		>/dev/null 2>&1 <<<"$source_ips"; then
		problem "TF_VAR_bootstrap_ssh_source_ips must be a JSON array of CIDRs"
	elif ! jq -e 'all(.[]; test("^([0-9]{1,3}\\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$"))' \
		>/dev/null <<<"$source_ips"; then
		problem "TF_VAR_bootstrap_ssh_source_ips accepts IPv4 CIDRs only"
	elif jq -e 'any(.[]; endswith("/0"))' >/dev/null <<<"$source_ips"; then
		problem "TF_VAR_bootstrap_ssh_source_ips must not contain an IPv4 /0"
	# The prefixes come from the fleet contract, so this rejects the same example
	# addresses OpenTofu and validate-fleet.py reject.
	elif jq -e --argjson prefixes "$(fleet_contract '.documentation_ipv4_prefixes')" \
		'any(.[]; . as $cidr | $prefixes | any(. as $prefix | $cidr | startswith($prefix)))' \
		>/dev/null <<<"$source_ips"; then
		problem "replace the example bootstrap SSH CIDR with your public IPv4 /32"
	fi
fi

if command -v uv >/dev/null && [ -f "$inventory_file" ]; then
	if ! "$repo_root/scripts/validate-fleet.py" "$inventory_file"; then
		fail=1
	fi
fi

# Three values live in both layers and can disagree. Nothing else reads the
# inventory and every provider at once, so the comparison belongs here.
if command -v uv >/dev/null && command -v jq >/dev/null && [ -f "$inventory_file" ]; then
	if ! providers_json="$(fleet_provider_hosts)"; then
		problem "a fleet provider could not report its hosts"
	else
		while IFS= read -r message; do
			[ -n "$message" ] && problem "$message"
		done < <(jq -r --argjson providers "$providers_json" '
      (._meta.hostvars // {}) as $hostvars
      | ($hostvars | keys) as $members
      | [$providers | to_entries[] | .key as $provider
         | .value | keys[] | {name: ., provider: $provider}] as $claims
      | ($claims | map(.name)) as $claimed
      | [$claims[] | select(.name | IN($members[]) | not)
         | "\(.name) is declared by the \(.provider) provider but is not in inventory"]
      + [$members[] | select(. | IN($claimed[]) | not)
         | "\(.) is in inventory but no provider declares it"]
      + [$claims | group_by(.name)[] | select(length > 1)
         | "\(.[0].name) is claimed by more than one provider: \(map(.provider) | join(", "))"]
      + [$claims[] | . as $claim
         | $providers[$claim.provider][$claim.name].admin_user as $created
         | $hostvars[$claim.name].ansible_user as $connects_as
         | select($created != null and $connects_as != null and $created != $connects_as)
         | "\($claim.name): the \($claim.provider) provider creates \($created), but ansible_user is \($connects_as)"]
      | .[]
    ' <<<"$(fleet_read_inventory)")
	fi
fi

if [ "$fail" -ne 0 ]; then
	exit 1
fi

echo "OK: fleet inventory, tools, and secrets look ready"
