#!/usr/bin/env bash
# Validate local tools and configuration before creating paid infrastructure.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

problem() {
  echo "ERROR: $*" >&2
  fail=1
}

for command in tofu uv just jq curl ssh ssh-keygen; do
  command -v "$command" >/dev/null || problem "missing command: $command"
done

if [ ! -f "$repo_root/.env" ]; then
  problem "missing .env; run 'just setup' and fill in the placeholders"
fi

if [ -z "${TF_VAR_hcloud_token:-}" ]; then
  problem "TF_VAR_hcloud_token is empty"
fi

if [ -z "${TF_VAR_ssh_public_key:-}" ]; then
  problem "TF_VAR_ssh_public_key is empty"
elif command -v ssh-keygen >/dev/null \
    && ! printf '%s\n' "$TF_VAR_ssh_public_key" | ssh-keygen -l -f - >/dev/null 2>&1; then
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
  elif jq -e 'index("0.0.0.0/0") != null' >/dev/null <<<"$source_ips"; then
    problem "TF_VAR_bootstrap_ssh_source_ips must not contain 0.0.0.0/0"
  elif jq -e 'index("203.0.113.10/32") != null' >/dev/null <<<"$source_ips"; then
    problem "replace the example bootstrap SSH CIDR with your public IPv4 /32"
  fi
fi

if [ "${TF_VAR_image:-ubuntu-24.04}" != "ubuntu-24.04" ]; then
  problem "only TF_VAR_image=ubuntu-24.04 is currently supported"
fi

if [[ "${TF_VAR_enable_public_ssh:-}" != "true" && "${TF_VAR_enable_public_ssh:-}" != "false" ]]; then
  problem "TF_VAR_enable_public_ssh must be true or false"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: local tools and configuration look ready"
