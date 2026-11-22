---
name: secret-leak-response
description: Guide an engineer through containing, rotating, purging, and preventing a leaked secret detected by gitleaks, GitHub push protection, or manual review. Use when a secret or private key was committed, pushed, or flagged by a scanner.
---

# Secret Leak Response

Follow [`docs/secret-leak-runbook.md`](../../docs/secret-leak-runbook.md) step by step.

## Hard rules

- **Never print, echo, log, or paste the secret value** in chat, commit messages, PRs, or tickets. Refer only to file path, line number, and credential type.
- **Rotate first, rewrite history second.** History rewriting does not invalidate an already-exposed credential.
- **Never run force-push or history-rewriting commands automatically.** Print the exact commands for the user to review and run after confirming team coordination.

## Workflow

1. **Triage:** Identify the file, commit(s), credential type, and whether the commit was pushed to any remote.
2. **Rotate:** Instruct the user to revoke and rotate the credential immediately and check provider audit logs. Wait for confirmation before moving to history cleanup.
3. **Scrub:**
   - Unpushed HEAD commit: guide `git commit --amend` after removing the secret.
   - Pushed history: provide the exact `git-filter-repo` and `git push --force-with-lease` steps from the runbook for the user to execute.
4. **Verify:** Run `pre-commit run gitleaks --all-files` (or `gitleaks git --redact`) and confirm zero findings.
5. **Harden:** Check `.gitignore`, `.pre-commit-config.yaml`, plugin hook status, and GitHub push protection (`scripts/check-github-guardrails.sh`).
