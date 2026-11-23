# Feature: agent-secret-guard v0.1

Objective: reusable Claude Code plugin + git/CI templates that enforce secrets handling and commit guardrails for a developer team; portfolio evidence for the Codento Senior AI Engineer JD.
Branch: `main` (scaffold) then `feat/v0.1` | Delivery: ask-on-risk, local only (publishing is the user's decision) | Test runner: `bats tests`

## Specs

Source: user accepted the proposal of 2026-11-22 (see L1-L2). Scope below comes from that proposal; items marked *assumption* were not stated by the user.

- **S1 — Installable plugin.** The repo is a valid Claude Code plugin and single-plugin marketplace. Check: `claude plugin validate .` passes.
- **S2 — Agent cannot read or edit secret files.** A `PreToolUse` hook blocks `Read`, `Edit`, `Write`, `MultiEdit`, `NotebookEdit`, `Grep`, and `Glob` calls that target secret files, and `Bash` commands that reference them. Secret files (*assumption*): `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, private SSH keys (`id_rsa`, `id_ed25519`, ... but not `*.pub`), `.npmrc`, `.pypirc`, `credentials.json`, `*service-account*.json`, `~/.aws/credentials`, `~/.ssh/*`, `~/.config/gcloud/*`. Templates `.env.example`, `.env.sample`, `.env.template` stay allowed. Blocked calls exit 2 with a reason on stderr. Check: bats tests per rule.
- **S3 — Agent cannot bypass git guardrails.** The same hook blocks `git commit`/`git push` with `--no-verify` (or `git commit -n`) and force pushes (`--force`, `-f`); `--force-with-lease` stays allowed (*assumption*). Check: bats tests per rule.
- **S4 — Commit guardrails.** `pre-commit` config with gitleaks (and private-key detection) that blocks commits containing secrets; shipped as a template for target repos and used by this repo itself.
- **S5 — GitHub guardrails.** CI workflow running the tests and gitleaks; documented checklist and script for secret scanning, push protection, and branch protection.
- **S6 — Leak runbook.** Runbook plus a skill: "write down how to prevent it" (JD wording) — rotate the secret, purge history, verify, prevent recurrence.
- **S7 — README.** Portfolio-grade README: problem, install, what each layer blocks, demo, limitations.
- **S8 — Rollout (deferred, needs explicit user OK).** Publish the repo, apply it to `edge-vision-zone-monitor` and `sim2real-data-engine`, add it to the CV portfolio section.

## Tasks

| ID | Specs | Route | Status | Evidence |
|---|---|---|---|---|
| T1 | S1 | inline | done | `a9a192a`, `claude plugin validate .` PASS |
| T2 | S2, S3 | inline (no writer trigger: single unit) | done | `2d096a0` + `85c208c`, 49/49 `bats tests/guard.bats` PASS, independent verifier PASS (Risk: item 2 security guard) |
| T3 | S4 | inline | done | `aec5914`, 5/5 `bats tests/install.bats` PASS, `claude plugin validate .` PASS |
| T4 | S5 | inline | done | `2fc757a`, 4/4 `bats tests/github_guardrails.bats` PASS |
| T5 | S6 | inline | done | `e7c7d63`, structural readback |
| T6 | S7 | inline | done | `ad6ae2f`, structural readback |
| T7 | S8 | needs user OK | blocked (publishing) | — |

Risk: T2 touches item 2 (security guard); verify with an independent verifier at feature end, not per task.
Forecast: ~600 authored changed lines; above 400 → ask-on-risk chain question before the commit that crosses it.

## Log

- **L1 (2026-11-22, verbatim):** "arranquemos como repo nuevo a la seccion de portafolio y terminamos la reecritura del cv con lo que ya tengo. Pero la fecha docente es 2019–2026 y si son 320+ alumnos"
- **L2 (2026-11-22, verbatim, context):** "Esto guardrails de secretos/pre-commit en tus repos no tengo, deberia hacerlo?" — answered yes; proposed layers: pre-commit + gitleaks, GitHub secret scanning/push protection/branch protection, agent hooks blocking `.env`/credential reads and dangerous commands, leak runbook, packaged as a reusable public plugin.
- **L3:** Environment: Claude Code 2.1.207 (`claude plugin validate` available), bats, jq present; gitleaks and pre-commit not installed (use `uvx pre-commit`, which bootstraps gitleaks).
- **L4 (2026-11-22):** Independent read-only verifier (`c5a044e7`) audited `a9a192a..ad6ae2f`, passed S1/S4/S5/S6/S7 and flagged 4 concrete blockers in `hooks/guard.sh` (secret dirs without trailing slash, attached/mixed-case `-c core.hooksPath`, `--git-dir`/`--work-tree`/`/usr/bin/git`, blind quote stripping) plus `~/.ssh/*.pub` order. Fixed all in `7122644` with 5 regression tests (53/53 `bats` PASS); scoped recheck returned PASS on all items. T7 (publish/rollout) remains blocked awaiting explicit user authorization.
- **L5 (2026-11-22, verbatim):** "Lo pasemos" — user approved migrating `hooks/guard.sh` to pure-stdlib `hooks/guard.py`.
- **L6 (2026-11-22):** Independent read-only verifier (`434dd993`) audited `2d096a0` (`hooks/guard.py`) and reported 8 concrete blockers (line continuations `\\\n`, env `/git` prefix, backticks/`bash -c`, `--no-veri` prefix, `GIT_CONFIG_*` overrides, unnormalized `.`/`..` paths, brace expansion/`*.env` globs, and 2 false positives `-oforce` / `-m "... .env ..."`). Fixed all 8 in `85c208c` (58/58 `bats tests` PASS, `claude plugin validate .` PASS); scoped recheck returned PASS on all 8 items. T7 (publish/rollout) remains blocked awaiting explicit user authorization.
