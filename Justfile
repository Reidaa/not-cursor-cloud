# Runbook commands — see README.md for the full bring-up order.
# Secrets (TF_VAR_hcloud_token, TF_VAR_ssh_public_key) can live in an
# untracked .env file; dotenv-load exports it for every recipe.

set dotenv-load

tofu_dir := "fleet/providers/hcloud"

default:
    @just --list

# Create ignored local configuration without overwriting existing files. The
# inventory holds no secrets; the other three hold fleet shape and addresses, so
# only those get 0600.
setup:
    @test -f .env || { cp .env.example .env; echo "Created .env"; }
    @test -f ansible/inventory/hosts.yml || { cp ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml; echo "Created Ansible inventory"; }
    @test -f {{ tofu_dir }}/devboxes.auto.tfvars.json || { cp {{ tofu_dir }}/devboxes.example.tfvars.json {{ tofu_dir }}/devboxes.auto.tfvars.json; echo "Created Hetzner DevBox specs"; }
    @test -f fleet/providers/manual/hosts.yml || { cp fleet/providers/manual/hosts.example.yml fleet/providers/manual/hosts.yml; echo "Created hand-made DevBox list"; }
    @chmod 600 .env {{ tofu_dir }}/devboxes.auto.tfvars.json fleet/providers/manual/hosts.yml
    @find {{ tofu_dir }} -maxdepth 1 -type f -name 'terraform.tfstate*' -exec chmod 600 {} +
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

# Verify one declared host's type and location are in stock.
check-availability machine:
    {{ tofu_dir }}/check-availability.sh {{ quote(machine) }}

# Poll every 60 seconds until one host's type is in stock.
wait-availability machine:
    {{ tofu_dir }}/check-availability.sh --wait {{ quote(machine) }}

plan: doctor
    umask 077; tofu -chdir={{ tofu_dir }} plan

apply: doctor
    umask 077; tofu -chdir={{ tofu_dir }} apply

output *ARGS:
    @tofu -chdir={{ tofu_dir }} output {{ ARGS }}

# Remove every declared Hetzner host. To remove one host, clear its
# delete_protection, apply, then drop it from the specs and apply again.
destroy-hcloud-fleet:
    umask 077; tofu -chdir={{ tofu_dir }} destroy

# Configure one host or an Ansible host pattern.
configure machine:
    scripts/configure.sh {{ quote(machine) }}

# Configure the fleet one host at a time.
configure-all:
    scripts/configure.sh devboxes

# Check that Ansible can connect to one host, a pattern, or the full fleet.
ping machine="devboxes":
    cd ansible && uv run ansible {{ quote(machine) }} --module-name ansible.builtin.ping

# Dry run with diff — use before and after changing versions.yml
check *ARGS:
    cd ansible && uv run ansible-playbook playbook.yml --check --diff {{ ARGS }}

syntax:
    cd ansible && uv run ansible-playbook playbook.yml --syntax-check

# Configure one new host through its first address.
bootstrap machine:
    scripts/bootstrap.sh {{ quote(machine) }}

smoke machine:
    scripts/smoke-test.sh {{ quote(machine) }}

smoke-all:
    scripts/smoke-test.sh devboxes

# --- Quality ---

fmt:
    tofu -chdir={{ tofu_dir }} fmt
    shfmt -w scripts fleet/providers
    uv run ruff format scripts
    uv run ansible-lint --fix ansible

lint:
    tofu -chdir={{ tofu_dir }} fmt -check -diff
    tofu -chdir={{ tofu_dir }} validate
    uv run yamllint .
    cd ansible && uv run ansible-lint
    # -x follows the sourced fleet library so its variables are checked too.
    shellcheck -x scripts/*.sh tests/*.sh
    shellcheck scripts/lib/*.sh fleet/providers/*/*.sh
    uv run ruff check scripts
    uv run ruff format --check scripts

test:
    tests/fleet-validation.sh
    tests/script-commands.sh
    cd ansible && uv run ansible-playbook -i ../tests/fixtures/inventory/releases.yml ../tests/ansible-supported-releases.yml
    cd ansible && uv run ansible-playbook -i ../tests/fixtures/tailscale-machine-names.yml ../tests/tailscale-machine-name.yml
    tofu -chdir={{ tofu_dir }} test

pre-commit:
    uv run pre-commit run --all-files

bcrypt-ing:
    #!/usr/bin/env -S uv run --with bcrypt --script
    import bcrypt, getpass;
    print(bcrypt.hashpw(getpass.getpass("input: ").encode(), bcrypt.gensalt()).decode())
