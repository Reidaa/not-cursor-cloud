#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$repo_root/scripts/validate-fleet.py"
fixtures="$repo_root/tests/fixtures/inventory"
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

expect_pass fleet.yml
expect_pass empty.yml

expect_fail invalid-name.yml
expect_fail child-groups.yml
expect_fail two-keepalive.yml
expect_fail quoted-keepalive.yml
expect_fail placeholder.yml

exit "$fail"
