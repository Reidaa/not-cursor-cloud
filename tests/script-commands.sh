#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures="$repo_root/tests/fixtures/inventory"
fake_bin="$repo_root/tests/scripts/fakes"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

cp "$fixtures/mixed.yml" "$temp_dir/hosts.yml"
chmod 600 "$temp_dir/hosts.yml"
touch "$temp_dir/commands.log"
touch "$temp_dir/.env"
inventory_hash="$(shasum "$temp_dir/hosts.yml")"

export ANSIBLE_INVENTORY_FILE="$temp_dir/hosts.yml"
export FLEET_ENV_FILE="$temp_dir/.env"
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

expect_success "stock lookup by host" "$repo_root/scripts/check-availability.sh" devbox-2
grep -q "cax31 is available in fsn1 for devbox-2" "$temp_dir/output" || fail=1

expect_failure "manual host stock rejection" \
	"$repo_root/scripts/check-availability.sh" devbox-3
expect_failure "unknown host rejection" \
	"$repo_root/scripts/check-availability.sh" devbox-99

expect_success "manual host may use MagicDNS after bootstrap" \
	"$repo_root/scripts/validate-inventory.py" "$fixtures/manual-magicdns.yml"

: >"$temp_dir/commands.log"
expect_success "Hetzner bootstrap IP lookup" \
	"$repo_root/scripts/bootstrap.sh" devbox-1
grep -q '"ansible_host":"192.0.2.10"' "$temp_dir/commands.log" || fail=1

: >"$temp_dir/commands.log"
expect_success "manual bootstrap address lookup" \
	"$repo_root/scripts/bootstrap.sh" devbox-3
grep -q '"ansible_host":"192.168.1.40"' "$temp_dir/commands.log" || fail=1

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

# configure must apply the fleet-wide inventory rules, not only the per-host
# ones the playbook checks.
ANSIBLE_INVENTORY_FILE="$fixtures/two-keepalive.yml" \
	expect_failure "configure rejects a second keepalive host" \
	"$repo_root/scripts/configure.sh" devboxes

if [ "$(shasum "$temp_dir/hosts.yml")" != "$inventory_hash" ]; then
	echo "FAIL  a command wrote inventory"
	fail=1
else
	echo "PASS  commands do not write inventory"
fi

exit "$fail"
