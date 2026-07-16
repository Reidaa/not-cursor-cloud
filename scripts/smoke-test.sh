#!/usr/bin/env bash
# Smoke test after provisioning or upgrades.
# Usage: scripts/smoke-test.sh <ssh-host>   (e.g. admin@agent-vps.tailnet.ts.net)
set -euo pipefail

host="${1:?usage: smoke-test.sh <ssh-host>}"
agent_user="${AGENT_USER:-agent}"
agent_host="${host#*@}"
agent_home="/home/$agent_user"
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

check_agent() {
  local desc="$1"; shift
  if ssh -o BatchMode=yes -l "$agent_user" "$agent_host" "$@" >/dev/null 2>&1; then
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
check "Herdr CLI is installed"              "sudo -u '$agent_user' -H /usr/local/bin/herdr --version"
check "Herdr config belongs to agent"       "test \"\$(sudo stat -c %U:%G '$agent_home/.config/herdr/config.toml')\" = '$agent_user:$agent_user'"
check "Herdr config directory is private"   "test \"\$(sudo stat -c %a '$agent_home/.config/herdr')\" = 700"
check "Herdr config file is private"        "test \"\$(sudo stat -c %a '$agent_home/.config/herdr/config.toml')\" = 600"
check "Herdr has no system service"         "! systemctl cat herdr >/dev/null 2>&1"
check "Herdr has no TCP listener"           "! sudo ss -ltnp | grep -q herdr"
check_agent "agent Tailscale SSH works"     "test \"\$(id -un)\" = '$agent_user'"
check_agent "mise is active for the agent"  "bash -ic 'declare -F mise >/dev/null && mise --version'"
check_agent "agent resolves managed Herdr"  "test \"\$(command -v herdr)\" = /usr/local/bin/herdr"
check_agent "agent resolves managed gh"     "test \"\$(command -v gh)\" = /usr/local/bin/gh"
check_agent "agent workspace is writable"   "test -w /srv/agent/workspaces"
check "cron service is active"               systemctl is-active cron
check "cron service is enabled"              systemctl is-enabled cron
check "Claude hello cron is installed"       "sudo crontab -u '$agent_user' -l | grep -Fxq \"0 */4 * * * /usr/local/bin/claude auth status >/dev/null 2>&1 && /usr/local/bin/claude --safe-mode --tools '' --print --no-session-persistence hello >/dev/null 2>&1\""
check "GitHub CLI supports T3 auth detection" \
  "test ! -e /run/not-cursor-cloud-gh-smoke && sudo -u '$agent_user' env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN -u GH_HOST GH_CONFIG_DIR=/run/not-cursor-cloud-gh-smoke gh auth status --json hosts 2>/dev/null | jq -e '.hosts | type == \"object\"'"
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
