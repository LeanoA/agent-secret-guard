# Secret Leak Response Runbook

When a secret is committed or pushed, **assume it is compromised**. Removing it from git history is necessary for hygiene, but it does **not** revoke the credential.

## 1. Rotate and revoke immediately (first, always)

1. Identify the credential type (API key, cloud service account, SSH key, DB password, token) **without** pasting the secret value into chat, issues, or logs.
2. Revoke the leaked credential in the provider console (Anthropic, Google Cloud IAM, AWS IAM, GitHub, etc.).
3. Issue a replacement credential and store it in your secret manager or local `.env` (gitignored).
4. Check provider audit logs for unauthorized usage during the exposure window.

## 2. Remove the secret from git history

- **If NOT yet pushed:**
  - Last commit only: remove the secret, stage the fix, and run `git commit --amend`.
  - Earlier local commits: use `git rebase -i` to edit/squash the offending commit.
- **If ALREADY pushed:**
  1. Coordinate with the team — history rewrite requires everyone to re-clone or reset.
  2. Rewrite history with `git-filter-repo` (preferred over `git filter-branch`):
     ```bash
     # Remove a leaked file from all commits
     git filter-repo --invert-paths --path path/to/leaked-file

     # Or scrub a literal string using a replacements file (never put the secret in shell history)
     git filter-repo --replace-text replacements.txt
     ```
  3. Force-push rewritten branches and tags (requires temporary coordination if branch protection blocks force push):
     ```bash
     git push --force-with-lease --all
     git push --force-with-lease --tags
     ```
  4. Contact GitHub Support if the commit was referenced in a PR or fork and must be purged from cached views.

## 3. Verify the repository is clean

```bash
pre-commit run gitleaks --all-files
# or directly:
gitleaks git --redact
```

Confirm exit code `0` with zero findings across the full history.

## 4. Prevent recurrence

1. Verify `.gitignore` excludes `.env`, `.env.*` (except `.env.example`), `*.pem`, `*.key`, and credential files.
2. Confirm `.pre-commit-config.yaml` with `gitleaks` and `detect-private-key` is committed and installed (`pre-commit install`).
3. Confirm the `agent-secret-guard` hook/plugin is enabled so the agent cannot read secret files or run `--no-verify`.
4. Confirm GitHub Secret Scanning and Push Protection are enabled (`bash scripts/check-github-guardrails.sh owner/repo`).
5. Record a brief blameless post-mortem note (what leaked, how it bypassed controls, which guardrail was added) — never include the secret value.
