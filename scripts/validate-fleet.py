#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12,<3.14"
# ///
"""Check the fleet-wide rules without changing inventory or remote hosts.

Reads the inventory the way Ansible does, then applies the rules that a single
playbook run cannot see, because they are about the fleet as a whole. Rules
about one provider's machines belong to that provider; rules that compare the
inventory against what a provider created belong to scripts/doctor.sh. Every
failure names the host it came from.
"""

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# The same contract OpenTofu and the Ansible playbook read, so the rules here
# and the rules that guard paid resources cannot drift apart.
CONTRACT = json.loads((REPO_ROOT / "fleet" / "contract.json").read_text())

# Values a person left behind after copying hosts.example.yml.
PLACEHOLDER = re.compile(
    r"replace[_ -]?me|change[_ -]?me|placeholder|example\.(com|net|org|test)",
    re.IGNORECASE,
)

failed = False


def problem(message: str) -> None:
    global failed
    print(f"ERROR: {message}", file=sys.stderr)
    failed = True


def command_output(*args: str) -> str:
    """Standard output of a command, or "" if it is missing or fails."""
    if not shutil.which(args[0]):
        return ""
    result = subprocess.run(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    return result.stdout if result.returncode == 0 else ""


def read_inventory(inventory_file: Path) -> dict:
    """Ansible's own view of the inventory, so this agrees with a real run."""
    # The uv run in this file's shebang exports VIRTUAL_ENV for its own throwaway
    # environment. Drop it, or the nested run warns that it does not match the
    # project's .venv.
    env = {key: value for key, value in os.environ.items() if key != "VIRTUAL_ENV"}
    result = subprocess.run(
        ["uv", "run", "ansible-inventory", "-i", str(inventory_file), "--list"],
        cwd=REPO_ROOT,
        env=env,
        stdout=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        problem(f"Ansible could not parse {inventory_file}")
        sys.exit(1)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        problem(f"Ansible did not return JSON for {inventory_file}")
        sys.exit(1)


def strings(value) -> list:
    """Every string anywhere in the inventory, keys excluded."""
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [text for item in value.values() for text in strings(item)]
    if isinstance(value, list):
        return [text for item in value for text in strings(item)]
    return []


def controller_addresses() -> set:
    """Names and addresses that mean "the machine running this check"."""
    addresses = {"localhost", "127.0.0.1", "::1"}
    addresses.update(command_output("hostname").split())
    addresses.update(command_output("hostname", "-s").split())
    if shutil.which("ifconfig"):
        for line in command_output("ifconfig").splitlines():
            fields = line.split()
            if len(fields) > 1 and fields[0] == "inet":
                addresses.add(fields[1])
    else:
        addresses.update(command_output("hostname", "-I").split())
    return addresses


def check_membership(inventory: dict, hosts: list, hostvars: dict) -> None:
    """One flat group holds the fleet, and every target is in it."""
    if inventory.get("devboxes", {}).get("children"):
        problem("devboxes must list its hosts directly, with no child groups")

    if sorted(hostvars) != sorted(hosts):
        problem("every target must belong to the devboxes group")

    name_pattern = re.compile(CONTRACT["machine_name_pattern"])
    for host in hosts:
        if not name_pattern.search(host):
            problem(f"{host} must match devbox-<positive integer>")


def check_keepalive(hostvars: dict) -> None:
    """The Claude keepalive job signs in as one account, so one host may run it."""
    enabled = []
    for host, host_vars in sorted(hostvars.items()):
        if "claude_keepalive_enabled" not in host_vars:
            continue
        value = host_vars["claude_keepalive_enabled"]
        if not isinstance(value, bool):
            problem(
                f"{host}: claude_keepalive_enabled must be a Boolean, not {value!r}"
            )
        elif value:
            enabled.append(host)

    if len(enabled) > 1:
        problem(
            "at most one host may enable the Claude keepalive job, but these do: "
            + ", ".join(enabled)
        )


def check_placeholders(inventory: dict) -> None:
    """The documentation IPv4 prefixes come from the fleet contract, so the
    example values this rejects stay in step with the ones OpenTofu and
    doctor.sh reject."""
    documentation = tuple(CONTRACT["documentation_ipv4_prefixes"])
    found = {
        text
        for text in strings(inventory)
        if PLACEHOLDER.search(text) or text.startswith(documentation)
    }
    for text in sorted(found):
        problem(f"inventory must not contain the placeholder value {text!r}")


def check_targets(hosts: list, hostvars: dict) -> None:
    """A DevBox named after the controller would point Ansible at this machine."""
    addresses = controller_addresses()
    for host in hosts:
        target = hostvars.get(host, {}).get("ansible_host") or host
        if target in addresses:
            problem(f"the controller must not appear as a target: {host} is {target}")


def main() -> int:
    default = REPO_ROOT / "ansible" / "inventory" / "hosts.yml"
    inventory_file = Path(sys.argv[1]) if len(sys.argv) > 1 else default

    if not inventory_file.is_file():
        problem(f"missing inventory: {inventory_file}")
        return 1

    inventory = read_inventory(inventory_file)
    hostvars = inventory.get("_meta", {}).get("hostvars", {})
    hosts = inventory.get("devboxes", {}).get("hosts") or []

    check_membership(inventory, hosts, hostvars)
    check_keepalive(hostvars)
    check_placeholders(inventory)
    check_targets(hosts, hostvars)

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
