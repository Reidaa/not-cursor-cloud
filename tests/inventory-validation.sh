#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$repo_root/scripts/validate-inventory.py"
fixtures="$repo_root/tests/fixtures/inventory"
# Host lookups that always fail, so a fixture host that happens to exist in the
# developer's own tailnet cannot change the result.
export PATH="$repo_root/tests/scripts/unresolvable:$PATH"
fail=0

expect_pass() {
	local fixture="$1"
	if "$validator" "$fixtures/$fixture" >/dev/null 2>&1; then
		echo "PASS  $fixture"
	else
		echo "FAIL  $fixture should pass"
		fail=1
	fi
}

expect_fail() {
	local fixture="$1"
	if "$validator" "$fixtures/$fixture" >/dev/null 2>&1; then
		echo "FAIL  $fixture should fail"
		fail=1
	else
		echo "PASS  $fixture"
	fi
}

expect_pass one-hcloud.yml
expect_pass several-hcloud.yml
expect_pass several-manual.yml
expect_pass mixed.yml
expect_pass empty.yml
expect_pass no-hosts-key.yml

expect_fail invalid-name.yml
expect_fail overlap.yml
expect_fail missing-hcloud-setting.yml
expect_fail two-keepalive.yml
expect_fail placeholder.yml
expect_fail invalid-image.yml
expect_fail invalid-boolean.yml
expect_fail manual-magicdns.yml
expect_fail quoted-keepalive.yml
expect_fail malformed-hosts.yml

exit "$fail"
