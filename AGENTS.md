# AGENTS.md

## Prose

- Never use a metaphor, simile or other figure of speech which you are used to seeing in print.
- Never use a long word where a short one will do.
- If it is possible to cut a word out, always cut it out.
- Never use the passive where you can use the active.
- Never use a foreign phrase, a scientific word or a jargon word if you can think of an everyday English equivalent.
- Break any of these rules sooner than say anything outright barbarous.

Review every prose output against these rules before delivering.

## Coding Guidelines

- Always strive for concise, simple solutions.
- If a problem can be solved in a simpler way, propose it.
- Write comments like the reader is new to the codebase but familiar with the goal of the project.
- Before creating code, brainstorm 3 different approaches to solve the problem and sort them by their probable effectiveness. Then, choose the best approach and implement it.
- Use logging to provide insight into failures. Don't use print for debugging. Don't use logging to hide stack traces.

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
