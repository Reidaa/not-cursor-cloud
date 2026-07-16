# AGENTS.md

## Code Style

- Always strive for concise, simple solutions.
- If a problem can be solved in a simpler way, propose it.
- Write comments like the reader is new to the codebase but familiar with the goal of the project.

## Ansible

- Keep independently versioned runtimes and products in dedicated Ansible roles rather than adding them to a general-purpose role.
- Do not run ansible playbook that could induce destructive changes by yourself
- Prefer `ansible.builtin.cron` for simple periodic jobs whose interval divides evenly into 24 hours; use systemd timers when precise elapsed intervals or service lifecycle controls are needed.

## Commit Guidelines

- Do not commit unless specifically asked to.
- Use Conventional Commits.
- Avoid overly verbose descriptions or unnecessary details.

## Autoimprovement

- Suggest to add new rules to AGENTS.md based on user input or PR comments, when a change request could be generalized as a rule.
- Suggest updates to the README.md file according to feature changes or additions
