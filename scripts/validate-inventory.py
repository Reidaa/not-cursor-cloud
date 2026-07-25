#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12,<3.14"
# ///
"""Check the fleet contract without changing inventory or remote hosts.

Reads the inventory the way Ansible does, then applies the rules that a single
playbook run cannot see: rules about the fleet as a whole, and rules that guard
paid Hetzner resources. Every failure names the host it came from.
"""

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# The same contract OpenTofu and the Ansible playbook read, so the checks here
# and the checks that guard paid resources cannot drift apart.
CONTRACT = json.loads((REPO_ROOT / "fleet-contract.json").read_text())

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


def group_hosts(inventory: dict, group: str) -> list:
    return inventory.get(group, {}).get("hosts") or []


def strings(value) -> list:
    """Every string anywhere in the inventory, keys excluded."""
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [text for item in value.values() for text in strings(item)]
    if isinstance(value, list):
        return [text for item in value for text in strings(item)]
    return []


def resolves(host: str) -> bool:
    """Whether a name resolves, on macOS through MagicDNS or on Linux."""
    lookup = command_output("dscacheutil", "-q", "host", "-a", "name", host)
    if any(line.startswith("ip_address:") for line in lookup.splitlines()):
        return True
    if not shutil.which("getent"):
        return False
    return (
        subprocess.run(
            ["getent", "hosts", host],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode
        == 0
    )


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


def check_groups(inventory: dict, hcloud: list, manual: list, hostvars: dict) -> None:
    children = sorted(inventory.get("devboxes", {}).get("children") or [])
    if children != ["hcloud_devboxes", "manual_devboxes"] or group_hosts(
        inventory, "devboxes"
    ):
        problem("devboxes must contain only hcloud_devboxes and manual_devboxes")

    if sorted(hostvars) != sorted(set(hcloud + manual)):
        problem("every target must belong to one child group")

    name_pattern = re.compile(CONTRACT["machine_name_pattern"])
    for host in hcloud + manual:
        if not name_pattern.search(host):
            problem(f"{host} must match devbox-<positive integer>")

    for host in sorted(set(hcloud) & set(manual)):
        problem(f"{host} must not belong to both child groups")


def check_hcloud_hosts(hcloud: list, hostvars: dict) -> None:
    """Settings that decide what OpenTofu creates and bills for."""
    type_pattern = re.compile(CONTRACT["hcloud_server_type_pattern"])
    locations = CONTRACT["hcloud_locations"]
    images = {f"ubuntu-{release}" for release in CONTRACT["ubuntu_releases"]}

    for host in hcloud:
        host_vars = hostvars.get(host, {})

        server_type = host_vars.get("hcloud_server_type")
        if not isinstance(server_type, str) or not type_pattern.search(server_type):
            problem(f"{host}: hcloud_server_type is not a server type: {server_type!r}")

        location = host_vars.get("hcloud_location")
        if location not in locations:
            problem(f"{host}: hcloud_location must be one of {', '.join(locations)}")

        image = host_vars.get("hcloud_image")
        if image not in images:
            problem(f"{host}: hcloud_image must be one of {', '.join(sorted(images))}")

        for flag in ("hcloud_enable_public_ssh", "hcloud_delete_protection"):
            if not isinstance(host_vars.get(flag), bool):
                problem(
                    f"{host}: {flag} must be a Boolean, not {host_vars.get(flag)!r}"
                )


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


def check_admin_user(hcloud: list, hostvars: dict) -> None:
    """cloud-init creates TF_VAR_admin_user on a new Hetzner host, and Ansible
    then connects as that host's ansible_user. If the two disagree, bootstrap
    cannot log in, so check it here instead of asking anyone to keep two files
    in step."""
    admin_user = os.environ.get("TF_VAR_admin_user")
    if not admin_user:
        return
    for host in hcloud:
        ansible_user = hostvars.get(host, {}).get("ansible_user")
        if ansible_user != admin_user:
            problem(
                f"{host}: ansible_user is {ansible_user!r}, "
                f"but TF_VAR_admin_user is {admin_user!r}"
            )


def check_placeholders(inventory: dict) -> None:
    """The documentation IPv4 prefixes come from the fleet contract, so the
    example addresses this rejects stay in step with the ones OpenTofu and
    doctor.sh reject."""
    documentation = tuple(CONTRACT["documentation_ipv4_prefixes"])
    found = {
        text
        for text in strings(inventory)
        if PLACEHOLDER.search(text) or text.startswith(documentation)
    }
    for text in sorted(found):
        problem(f"inventory must not contain the placeholder value {text!r}")


def check_targets(hcloud: list, manual: list, hostvars: dict) -> None:
    addresses = controller_addresses()
    for host in hcloud + manual:
        target = hostvars.get(host, {}).get("ansible_host") or host
        if target in addresses:
            problem(f"the controller must not appear as a target: {host} is {target}")

    # A manual host reaches its final name through MagicDNS, but before its
    # first run only an explicit address can get Ansible there.
    for host in manual:
        if hostvars.get(host, {}).get("ansible_host") is None and not resolves(host):
            problem(
                f"{host} must set an initial ansible_host or resolve through MagicDNS"
            )


def main() -> int:
    default = REPO_ROOT / "ansible" / "inventory" / "hosts.yml"
    inventory_file = Path(sys.argv[1]) if len(sys.argv) > 1 else default

    if not inventory_file.is_file():
        problem(f"missing inventory: {inventory_file}")
        return 1

    inventory = read_inventory(inventory_file)
    hostvars = inventory.get("_meta", {}).get("hostvars", {})
    hcloud = group_hosts(inventory, "hcloud_devboxes")
    manual = group_hosts(inventory, "manual_devboxes")

    check_groups(inventory, hcloud, manual, hostvars)
    check_hcloud_hosts(hcloud, hostvars)
    check_keepalive(hostvars)
    check_admin_user(hcloud, hostvars)
    check_placeholders(inventory)
    check_targets(hcloud, manual, hostvars)

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
