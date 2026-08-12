#!/usr/bin/env bash
set -euo pipefail

role=ansible/roles/herdr/tasks/main.yml

test -f "$role"
grep -Fq 'herdr_version:' versions.yml
grep -Fq 'herdr_checksums:' versions.yml
grep -Fq 'https://github.com/herdrdev/herdr/releases/download/v{{ herdr_version }}/herdr-linux-{{ ansible_architecture }}' "$role"
grep -Fq 'checksum: "sha256:{{ herdr_checksums[ansible_architecture] }}"' "$role"
grep -Fq 'dest: /usr/local/bin/herdr' "$role"
grep -Eq '^    - herdr$' ansible/playbook.yml
grep -Fq 'Herdr is installed' scripts/smoke-test.sh
