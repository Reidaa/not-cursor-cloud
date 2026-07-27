#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures="$repo_root/tests/fixtures"
fake_bin="$repo_root/tests/scripts/fakes"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

cp "$fixtures/inventory/fleet.yml" "$temp_dir/hosts.yml"
touch "$temp_dir/commands.log"
touch "$temp_dir/.env"
inventory_hash="$(shasum "$temp_dir/hosts.yml")"

export ANSIBLE_INVENTORY_FILE="$temp_dir/hosts.yml"
export FLEET_ENV_FILE="$temp_dir/.env"
# Fixture providers, so a check never depends on the real fleet or on state.
export FLEET_PROVIDERS_DIR="$fixtures/providers"
export FLEET_HCLOUD_SPECS_FILE="$fixtures/hcloud-devboxes.tfvars.json"
export TEST_COMMAND_LOG="$temp_dir/commands.log"
export REAL_UV
REAL_UV="$(command -v uv)"
export PATH="$fake_bin:$PATH"
export TF_VAR_hcloud_token=test-token
export TF_VAR_ssh_public_key="ssh-ed25519 test"
export TF_VAR_bootstrap_ssh_source_ips='["1.1.1.1/32"]'

fail=0

expect_success() {
	local name="$1"
	shift
	if "$@" >"$temp_dir/output" 2>&1; then
		echo "PASS  $name"
	else
		echo "FAIL  $name"
		cat "$temp_dir/output"
		fail=1
	fi
}

expect_failure() {
	local name="$1"
	shift
	if "$@" >"$temp_dir/output" 2>&1; then
		echo "FAIL  $name"
		fail=1
	else
		echo "PASS  $name"
	fi
}

availability="$repo_root/fleet/providers/hcloud/check-availability.sh"

expect_success "stock lookup by host" "$availability" devbox-2
grep -q "cax31 is available in fsn1 for devbox-2" "$temp_dir/output" || fail=1

# A host with no Hetzner spec has no stock to check, whoever made it.
expect_failure "hand-made host stock rejection" "$availability" devbox-3
expect_failure "unknown host rejection" "$availability" devbox-99

# The fleet layers agree, so doctor reports no drift.
expect_success "doctor accepts a fleet with no drift" "$repo_root/scripts/doctor.sh"

# A host every provider has forgotten must be reported, not quietly skipped.
sed 's/    devbox-3:/    devbox-3:\n    devbox-4:/' "$fixtures/inventory/fleet.yml" \
	>"$temp_dir/undeclared.yml"
ANSIBLE_INVENTORY_FILE="$temp_dir/undeclared.yml" \
	expect_failure "doctor reports a host no provider declares" \
	"$repo_root/scripts/doctor.sh"
grep -q "devbox-4 is in inventory but no provider declares it" "$temp_dir/output" || fail=1

# A host a provider bills for but Ansible never configures must be reported too.
grep -v '^    devbox-2:$' "$fixtures/inventory/fleet.yml" >"$temp_dir/unlisted.yml"
ANSIBLE_INVENTORY_FILE="$temp_dir/unlisted.yml" \
	expect_failure "doctor reports a declared host missing from inventory" \
	"$repo_root/scripts/doctor.sh"
grep -q "devbox-2 is declared by the hcloud provider but is not in inventory" \
	"$temp_dir/output" || fail=1

# Two providers claiming one host means neither can be trusted for its address.
FLEET_PROVIDERS_DIR="$fixtures/providers-overlap" \
	expect_failure "doctor reports a host two providers claim" \
	"$repo_root/scripts/doctor.sh"
grep -q "devbox-1 is claimed by more than one provider: hcloud, manual" \
	"$temp_dir/output" || fail=1

# cloud-init creates one account and Ansible connects as another: bootstrap
# could not log in, so the disagreement must fail here.
sed 's/      ansible_user: local-admin/      ansible_user: someone-else/' \
	"$fixtures/inventory/fleet.yml" >"$temp_dir/wrong-user.yml"
ANSIBLE_INVENTORY_FILE="$temp_dir/wrong-user.yml" \
	expect_failure "doctor reports an admin account mismatch" \
	"$repo_root/scripts/doctor.sh"
grep -q "devbox-3: the manual provider creates local-admin" "$temp_dir/output" || fail=1

: >"$temp_dir/commands.log"
expect_success "Hetzner bootstrap address lookup" \
	"$repo_root/scripts/bootstrap.sh" devbox-1
grep -q '"ansible_host":"192.0.2.10"' "$temp_dir/commands.log" || fail=1

: >"$temp_dir/commands.log"
expect_success "hand-made bootstrap address lookup" \
	"$repo_root/scripts/bootstrap.sh" devbox-3
grep -q '"ansible_host":"192.168.1.40"' "$temp_dir/commands.log" || fail=1

# A declared host that nobody has created yet has no address to bootstrap
# through, and must say so rather than reach for an empty one.
expect_failure "bootstrap refuses a host with no address" \
	"$repo_root/scripts/bootstrap.sh" devbox-2
grep -q "No provider has an address for devbox-2" "$temp_dir/output" || fail=1

expect_success "one-host smoke selection" \
	"$repo_root/scripts/smoke-test.sh" devbox-1
grep -q "PASS  devbox-1 smoke test" "$temp_dir/output" || fail=1

expect_success "pattern smoke selection" \
	"$repo_root/scripts/smoke-test.sh" "devbox-1:devbox-3"
grep -q "PASS  devbox-1 smoke test" "$temp_dir/output" || fail=1
grep -q "PASS  devbox-3 smoke test" "$temp_dir/output" || fail=1

expect_success "full-fleet smoke selection" \
	"$repo_root/scripts/smoke-test.sh" devboxes
grep -q "PASS  devbox-1 smoke test" "$temp_dir/output" || fail=1
grep -q "PASS  devbox-2 smoke test" "$temp_dir/output" || fail=1
grep -q "PASS  devbox-3 smoke test" "$temp_dir/output" || fail=1

# A failed inventory read must report its own error rather than look like a
# pattern that matched nothing.
printf '#!/bin/sh\necho "uv: simulated failure" >&2\nexit 3\n' >"$temp_dir/uv"
chmod +x "$temp_dir/uv"
PATH="$temp_dir:$PATH" expect_failure "host selection reports a failed read" \
	"$repo_root/scripts/smoke-test.sh" devboxes
grep -q "simulated failure" "$temp_dir/output" || fail=1
if grep -q "No hosts match" "$temp_dir/output"; then
	fail=1
fi

: >"$temp_dir/commands.log"
expect_success "configure runs the playbook" \
	"$repo_root/scripts/configure.sh" devboxes
grep -q "ansible-playbook playbook.yml --limit devboxes" "$temp_dir/commands.log" || fail=1

# configure must apply the fleet-wide rules, not only the per-host ones the
# playbook checks.
ANSIBLE_INVENTORY_FILE="$fixtures/inventory/two-keepalive.yml" \
	expect_failure "configure rejects a second keepalive host" \
	"$repo_root/scripts/configure.sh" devboxes

if [ "$(shasum "$temp_dir/hosts.yml")" != "$inventory_hash" ]; then
	echo "FAIL  a command wrote inventory"
	fail=1
else
	echo "PASS  commands do not write inventory"
fi

exit "$fail"
