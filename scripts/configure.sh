#!/usr/bin/env bash
# Configure one host, an Ansible host pattern, or the full fleet.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/fleet.sh
source "$repo_root/scripts/lib/fleet.sh"

pattern="${1:-devboxes}"
if [ "$#" -gt 1 ]; then
	echo "usage: configure.sh [devbox-N|ansible-pattern]" >&2
	exit 1
fi

# Some inventory rules cover the whole fleet — only one host may run the Claude
# keepalive job, for example — so check the whole file, not only the hosts this
# run touches. just bootstrap gets the same check through doctor.sh.
"$repo_root/scripts/validate-inventory.py" "$fleet_inventory_file"

# Resolving the pattern first turns a typo into an error here rather than an
# Ansible run that silently matches nothing. The playbook's pre-tasks then check
# the name and operating system of every host it reaches.
hosts=()
while IFS= read -r machine; do
	hosts+=("$machine")
done < <(fleet_select_hosts "$pattern")
if [ "${#hosts[@]}" -eq 0 ]; then
	echo "No hosts match: $pattern" >&2
	exit 1
fi

echo "Configuring: ${hosts[*]}"
cd "$repo_root/ansible"
uv run ansible-playbook playbook.yml --limit "$pattern"
