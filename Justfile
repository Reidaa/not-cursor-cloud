# Runbook commands — see README.md for the full bring-up order.
# Secrets (TF_VAR_hcloud_token, TF_VAR_ssh_public_key) can live in an
# untracked .env file; dotenv-load exports it for every recipe.

set dotenv-load

tofu_dir := "tofu"

default:
    @just --list

# Create ignored local configuration without overwriting existing files.
setup:
    @test -f .env || { cp .env.example .env; echo "Created .env"; }
    @test -f ansible/inventory/hosts.yml || { cp ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml; echo "Created Ansible inventory"; }
    @chmod 600 .env ansible/inventory/hosts.yml
    @find tofu -maxdepth 1 -type f -name 'terraform.tfstate*' -exec chmod 600 {} +
    @echo "Edit .env, then run: just doctor"

# Check tools, credentials, SSH key, and secure bootstrap settings.
doctor:
    scripts/doctor.sh

# Install local tooling (uv-managed Ansible) and init OpenTofu
init:
    uv sync --locked
    tofu -chdir={{ tofu_dir }} init -input=false

# Install the repository's Git pre-commit hook.
install-hooks:
    uv run pre-commit install

whats-my-ip:
    @curl --fail --silent --show-error --ipv4 https://ifconfig.me/ip

# Verify the server type is in stock before provisioning (CX plans sell out)
check-availability *ARGS:
    scripts/check-availability.sh {{ ARGS }}

# Poll every 60s until the server type is in stock, then exit 0
wait-availability *ARGS:
    scripts/check-availability.sh --wait {{ ARGS }}

plan:
    umask 077; tofu -chdir={{ tofu_dir }} plan

apply:
    umask 077; tofu -chdir={{ tofu_dir }} apply

output *ARGS:
    @tofu -chdir={{ tofu_dir }} output {{ ARGS }}

# Set the Ansible SSH target from the provisioned server's public IPv4.
update-inventory:
    scripts/update-inventory.sh

# Switch Ansible to a verified Tailscale MagicDNS hostname.
set-inventory-host host:
    scripts/update-inventory.sh {{ quote(host) }}

destroy:
    umask 077; tofu -chdir={{ tofu_dir }} destroy

# TODO: Design a simple, isolated way to close public SSH without applying unrelated infrastructure changes.

# Run the playbook; extra Ansible arguments pass through.
configure *ARGS:
    cd ansible && uv run ansible-playbook playbook.yml {{ ARGS }}

# Dry run with diff — use before and after changing versions.yml (plan Step 10)
check *ARGS:
    cd ansible && uv run ansible-playbook playbook.yml --check --diff {{ ARGS }}

syntax:
    cd ansible && uv run ansible-playbook playbook.yml --syntax-check

# tofu apply + wait for SSH + full playbook run
bootstrap *ARGS:
    scripts/bootstrap.sh {{ ARGS }}

# e.g. just smoke admin@agent-vps.<tailnet>.ts.net
smoke host:
    scripts/smoke-test.sh {{ host }}

# --- Quality ---

fmt:
    tofu -chdir={{ tofu_dir }} fmt

lint:
    tofu -chdir={{ tofu_dir }} fmt -check -diff
    tofu -chdir={{ tofu_dir }} validate
    uv run yamllint .
    cd ansible && uv run ansible-lint
    shellcheck scripts/*.sh

pre-commit:
    uv run pre-commit run --all-files
