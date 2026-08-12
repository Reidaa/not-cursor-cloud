#!/usr/bin/env bash
set -euo pipefail

role=ansible/roles/t3code

grep -Fq 'tailscale serve --https=443 off' "$role/tasks/main.yml"
grep -Fq 't3code_host: 0.0.0.0' ansible/group_vars/all.yml
grep -Fq -- '--host {{ t3code_host }} --port {{ t3code_port }}' \
	"$role/templates/t3code.service.j2"

if grep -Fq 'tailscale serve --bg' "$role/tasks/main.yml"; then
	echo 'T3 Code must not use Tailscale Serve' >&2
	exit 1
fi
