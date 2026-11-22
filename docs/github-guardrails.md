# GitHub Repository Guardrails

Local hooks protect the developer's machine, but anyone (or any CI misconfiguration) can bypass local hooks. Repository-level controls on GitHub are the server-side backstop.

## Recommended Controls

1. **Secret scanning** — detects known credential patterns across the entire repository history.
2. **Push protection** — blocks `git push` at the server before a secret ever lands on GitHub.
3. **Branch protection (or Rulesets) on `main`**:
   - Require pull requests before merging (no direct pushes to `main`).
   - Require status checks to pass (`Bats test suite`, `Gitleaks secret scan`).
   - Block force pushes and branch deletion.

## Audit Script

Use [`scripts/check-github-guardrails.sh`](../scripts/check-github-guardrails.sh) to audit a repository via the GitHub CLI (`gh`):

```bash
bash scripts/check-github-guardrails.sh owner/repo
```

It is read-only and reports PASS/FAIL/UNKNOWN for secret scanning, push protection, and `main` branch protection.

## Enabling via `gh` (manual, explicit action)

```bash
# Enable secret scanning + push protection (public repos or GitHub Advanced Security)
gh api -X PATCH repos/OWNER/REPO \
  -f 'security_and_analysis[secret_scanning][status]=enabled' \
  -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled'
```

Branch protection is best configured through **Settings → Rules → Rulesets** (or **Settings → Branches**) so you can require your exact CI check names.
