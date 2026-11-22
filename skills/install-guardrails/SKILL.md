---
name: install-guardrails
description: Install commit guardrails (pre-commit + gitleaks secret scanning + private-key detection) into a git repository. Use when the user asks to add secret scanning, commit guardrails, or pre-commit hooks to a repo.
---

# Install commit guardrails

Adds a `pre-commit` configuration that blocks commits containing secrets (gitleaks) or private keys, then installs the git hook.

## Steps

1. Confirm the target repository with the user (default: the current working directory).
2. Run the installer from this skill's directory:

   ```bash
   bash <this-skill-dir>/scripts/install.sh <target-repo>
   ```

3. Handle the result:
   - exit `0`: config created and hook installed. Continue with step 4.
   - exit `1` with "already exists": do NOT overwrite. Show the user the hooks in `templates/pre-commit-config.yaml` and propose a merge into their existing `.pre-commit-config.yaml`.
   - exit `3`: `pre-commit` is missing. Tell the user to install it (`pipx install pre-commit` or `brew install pre-commit`), then run `pre-commit install`.
4. Scan the existing files once: `pre-commit run --all-files`. If gitleaks reports findings, stop and follow the `secret-leak-response` skill. Never print the secret values.
5. Tell the user to commit `.pre-commit-config.yaml` so the whole team gets the same hooks.

## Rules

- Never bypass the hooks (`--no-verify`, `-n`, `core.hooksPath`). If a hook fails, fix the cause or ask the user.
- False positive? Add a `gitleaks:allow` comment on that line or a `.gitleaksignore` entry, and say so to the user.
