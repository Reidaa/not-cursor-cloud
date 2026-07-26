#!/usr/bin/env bash
# Smoke test one host, an Ansible host pattern, or the full fleet.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/fleet.sh
source "$repo_root/scripts/lib/fleet.sh"

fleet_require_hosts "smoke-test.sh [devbox-N|ansible-pattern]" "$@"

inventory_json="$(fleet_read_inventory)"
fail=0

# One agent account serves the whole fleet, so its name is checked once here
# rather than on every host.
agent_user="${AGENT_USER:-agent}"
if [[ ! "$agent_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
	echo "Invalid AGENT_USER: $agent_user" >&2
	exit 1
fi

# smoke_host sets host, agent_host, and host_fail before running any check.
host=""
agent_host=""
host_fail=0

check() {
	local desc="$1"
	shift
	if ssh -o BatchMode=yes "$host" "$@" >/dev/null 2>&1; then
		echo "PASS  $desc"
	else
		echo "FAIL  $desc"
		fail=1
		host_fail=1
	fi
}

check_agent() {
	local desc="$1"
	shift
	if ssh -o BatchMode=yes -l "$agent_user" "$agent_host" "$@" >/dev/null 2>&1; then
		echo "PASS  $desc"
	else
		echo "FAIL  $desc"
		fail=1
		host_fail=1
	fi
}

smoke_host() {
	local machine="$1"
	local address
	local admin_user
	local keepalive_enabled
	local public_ip

	# A host bootstrapped without a fixed address answers to its MagicDNS name.
	address="$(fleet_host_var_or "$inventory_json" "$machine" ansible_host "$machine")"
	admin_user="$(fleet_host_var "$inventory_json" "$machine" ansible_user)"
	host="$admin_user@$address"
	agent_host="$address"
	host_fail=0
	keepalive_enabled="$(fleet_host_var_or \
		"$inventory_json" "$machine" claude_keepalive_enabled false)"

	echo "==> $machine ($host)"

	check "t3code service is active" systemctl is-active t3code
	check "t3code service is enabled" systemctl is-enabled t3code
	check "T3 Code answers on localhost" curl --fail --silent http://127.0.0.1:3773
	check "tailscaled is active" systemctl is-active tailscaled
	check "T3 Code Serve is configured" "tailscale serve status | grep -q 3773"
	check "agent user exists" "id '$agent_user'"
	check "agent user has no sudo" "id '$agent_user' >/dev/null && ! sudo -l -U '$agent_user' | grep -q 'may run'"
	check "OpenCode CLI is installed" "sudo -u '$agent_user' opencode --version"
	check_agent "agent Tailscale SSH works" "test \"\$(id -un)\" = '$agent_user'"
	check_agent "mise is active for the agent" "bash -ic 'declare -F mise >/dev/null && mise --version'"
	check_agent "agent resolves managed gh" "test \"\$(command -v gh)\" = /usr/local/bin/gh"
	for cli in claude codex opencode; do
		check_agent "$cli-yolo alias is defined for the agent" \
			"bash -ic 'alias $cli-yolo'"
	done
	check_agent "agent workspace is writable" "test -w /srv/agent/workspaces"
	check "cron service is active" systemctl is-active cron
	check "cron service is enabled" systemctl is-enabled cron
	if [ "$keepalive_enabled" = "true" ]; then
		check "Claude hello cron is installed" "sudo crontab -u '$agent_user' -l | grep -Fxq \"0 */4 * * * /usr/local/bin/claude auth status >/dev/null 2>&1 && /usr/local/bin/claude --safe-mode --tools '' --print --no-session-persistence hello >/dev/null 2>&1\""
	else
		check "Claude hello cron is absent" "! sudo crontab -u '$agent_user' -l 2>/dev/null | grep -Fq 'claude --safe-mode'"
	fi
	check "disk usage below 90%" "test \"\$(df --output=pcent / | tail -1 | tr -dc 0-9)\" -lt 90"

	# Application ports must NOT be reachable on the public IP.
	public_ip="$(ssh -o BatchMode=yes "$host" "curl -s -4 ifconfig.me" || true)"
	if [ -n "$public_ip" ] && curl --silent --max-time 5 "http://$public_ip:3773" >/dev/null 2>&1; then
		echo "FAIL  T3 Code is publicly reachable on $public_ip:3773 — fix immediately"
		fail=1
		host_fail=1
	else
		echo "PASS  T3 Code is not publicly reachable"
	fi

	if [ "$host_fail" -eq 0 ]; then
		echo "PASS  $machine smoke test"
	else
		echo "FAIL  $machine smoke test"
	fi
}

for machine in "${fleet_hosts[@]}"; do
	smoke_host "$machine"
done

exit "$fail"
