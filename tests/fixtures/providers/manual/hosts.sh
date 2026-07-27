#!/usr/bin/env bash
# Stands in for a machine you made yourself, still reached by a fixed address.
set -euo pipefail

cat <<'JSON'
{
  "devbox-3": {"address": "192.168.1.40", "admin_user": "local-admin"}
}
JSON
