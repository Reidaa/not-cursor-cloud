#!/usr/bin/env bash
# Configure one host, an Ansible host pattern, or the full fleet.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/fleet.sh
source "$repo_root/scripts/lib/fleet.sh"

# Some inventory rules cover the whole fleet — only one host may run the Claude
# keepalive job, for example — so check the whole file, not only the hosts this
# run touches. just bootstrap gets the same check through doctor.sh.
"$repo_root/scripts/validate-inventory.py" "$fleet_inventory_file"

# The playbook's pre-tasks then check the name and operating system of every
# host it reaches.
fleet_require_hosts "configure.sh [devbox-N|ansible-pattern]" "$@"

echo "Configuring: ${fleet_hosts[*]}"
cd "$repo_root/ansible"
uv run ansible-playbook playbook.yml --limit "$fleet_pattern"
