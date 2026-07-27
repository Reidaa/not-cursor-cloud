#!/usr/bin/env bash
# Claims devbox-1 as well, so no provider owns it and neither can be trusted
# for its address.
set -euo pipefail

cat <<'JSON'
{
  "devbox-1": {"address": "192.168.1.40", "admin_user": "admin"},
  "devbox-2": {"address": null, "admin_user": "admin"},
  "devbox-3": {"address": "192.168.1.41", "admin_user": "local-admin"}
}
JSON
