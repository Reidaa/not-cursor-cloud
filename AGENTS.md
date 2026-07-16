# AGENTS.md

- Do not run the playbook unless explicitly asked

## Code Style

- Always strive for concise, simple solutions.
- If a problem can be solved in a simpler way, propose it.
- Write comments like the reader is new to the codebase but familiar with the goal of the project.

## Provisioning

- Prefer `ansible.builtin.cron` for simple periodic jobs whose interval divides evenly into 24 hours; use systemd timers when precise elapsed intervals or service lifecycle controls are needed.

## Commit Guidelines

- Do not commit unless specifically asked to.
- Use Conventional Commits.
- Avoid overly verbose descriptions or unnecessary details.

## Autoimprovement

- Suggest to add new rules to AGENTS.md based on user input or PR comments, when a change request could be generalized as a rule.
- Suggest updates to the README.md file according to feature changes or additions
