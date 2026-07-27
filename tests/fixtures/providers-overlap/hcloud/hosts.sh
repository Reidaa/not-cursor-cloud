#!/usr/bin/env bash
# Claims devbox-1, which the neighbouring manual provider also claims.
set -euo pipefail

cat <<'JSON'
{
  "devbox-1": {"address": "192.0.2.10", "admin_user": "admin"}
}
JSON
