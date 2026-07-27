#!/usr/bin/env bash
# Stands in for the Hetzner provider. devbox-2 has no address yet, which is what
# a declared but not-yet-created host looks like.
set -euo pipefail

cat <<'JSON'
{
  "devbox-1": {"address": "192.0.2.10", "admin_user": "admin"},
  "devbox-2": {"address": null, "admin_user": "admin"}
}
JSON
