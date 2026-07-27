#!/usr/bin/env bash
# Print the DevBoxes you made yourself, in the shape every provider prints:
#
#   {"devbox-2": {"address": "192.168.1.40", "admin_user": "local-admin"}}
#
# address is null once the entry drops it, which means the host answers to its
# own name through MagicDNS and needs no first-run address any more.
set -euo pipefail

provider_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$provider_dir/../../.." && pwd)"
hosts_file="$provider_dir/hosts.yml"

if [ ! -f "$hosts_file" ]; then
	echo '{}'
	exit 0
fi

# The file is hand-written YAML so it can carry comments. Python and PyYAML
# already come with Ansible, so read it with those rather than add a YAML tool.
uv run --project "$repo_root" python -c '
import json
import sys

import yaml

hosts = yaml.safe_load(open(sys.argv[1])) or {}
print(
    json.dumps(
        {
            name: {
                "address": (entry or {}).get("address"),
                "admin_user": (entry or {}).get("admin_user", "admin"),
            }
            for name, entry in hosts.items()
        }
    )
)
' "$hosts_file"
