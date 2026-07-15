#!/usr/bin/env bash
# Smoke test after provisioning or upgrades (plan Steps 4 and 10).
# Usage: scripts/smoke-test.sh <ssh-host>   (e.g. admin@agent-vps.tailnet.ts.net)
set -euo pipefail

host="${1:?usage: smoke-test.sh <ssh-host>}"
agent_user="${AGENT_USER:-agent}"
fail=0

if [[ ! "$agent_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "Invalid AGENT_USER: $agent_user" >&2
  exit 1
fi

check() {
  local desc="$1"; shift
  if ssh -o BatchMode=yes "$host" "$@" >/dev/null 2>&1; then
    echo "PASS  $desc"
  else
    echo "FAIL  $desc"
    fail=1
  fi
}

check "t3code service is active"            systemctl is-active t3code
check "t3code service is enabled"           systemctl is-enabled t3code
check "T3 Code answers on localhost"        curl --fail --silent http://127.0.0.1:3773
check "tailscaled is active"                systemctl is-active tailscaled
check "Tailscale Serve is configured"       "tailscale serve status | grep -q 3773"
check "agent user exists"                   "id '$agent_user'"
check "agent user has no sudo"              "id '$agent_user' >/dev/null && ! sudo -l -U '$agent_user' | grep -q 'may run'"
check "OpenCode CLI is installed"           "sudo -u '$agent_user' opencode --version"
check "disk usage below 90%"                "test \"\$(df --output=pcent / | tail -1 | tr -dc 0-9)\" -lt 90"

# The GUI must NOT be reachable on the public IP.
public_ip="$(ssh -o BatchMode=yes "$host" "curl -s -4 ifconfig.me" || true)"
if [ -n "$public_ip" ] && curl --silent --max-time 5 "http://$public_ip:3773" >/dev/null 2>&1; then
  echo "FAIL  T3 Code is publicly reachable on $public_ip:3773 — fix immediately"
  fail=1
else
  echo "PASS  T3 Code is not publicly reachable"
fi

exit "$fail"
