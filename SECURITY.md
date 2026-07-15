# Security policy

## Reporting a vulnerability

Use GitHub's **Security > Report a vulnerability** flow. Do not include
credentials, infrastructure state, private hostnames, or exploit details in a
public issue.

If private vulnerability reporting is unavailable, open a minimal public issue
requesting a private contact channel without disclosing the vulnerability.

## Scope

Security fixes target the latest version on the default branch. This project
provisions paid infrastructure and changes network access controls; always
review an OpenTofu plan before applying it.

Immediately revoke any credential that may have been exposed. Removing it from
the latest commit is not sufficient because it remains in Git history.
