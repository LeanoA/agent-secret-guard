# agent-secret-guard

Defense-in-depth secrets handling and commit guardrails for engineering teams adopting **AI coding agents** (ships as a native plugin for both **Claude Code** and **Antigravity CLI**, plus agent-agnostic git, CI, and runbook tooling).

## Why

When teams roll out AI coding agents onto real repositories, two failure modes show up immediately:

1. **Secret exposure to the agent context** — the agent reads `.env`, SSH keys, cloud credentials, or service-account JSONs while debugging.
2. **Guardrail bypasses** — when a pre-commit hook fails, an agent may try `git commit --no-verify` or `git push --force` to get unstuck.

`agent-secret-guard` combines three layers so teams can standardize safe defaults across repositories. Layer 1 ships natively for **Claude Code** (`.claude-plugin/`, `hooks/hooks.json`) and **Antigravity CLI** (`.antigravity-plugin/`, `hooks.json`); Layers 2, 3, and the `SKILL.md` playbooks work with **any** coding agent.

## Architecture (3 Layers)

| Layer | Mechanism | What it blocks |
|---|---|---|
| **1. Agent runtime** | `PreToolUse` hook ([`hooks/guard.py`](hooks/guard.py)) | File/search and shell access (`Read`/`Edit`/`Write`/`Grep`/`Glob`/`Bash` in Claude Code; `read_file`/`write_file`/`edit_file`/`grep_search`/`find_by_name`/`run_command` in Antigravity) to `.env*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, SSH keys, `~/.aws/*`, `~/.config/gcloud/*`, `.npmrc`, `.pypirc`, `credentials.json`, `*service-account*.json`. Also blocks `git commit/push --no-verify` (including `--no-veri`), `git commit -n`, `core.hooksPath` overrides (`-c`, `--config-env`, `GIT_CONFIG_*`), and `git push --force`/`-f`/`+refspec`. |
| **2. Local git** | `pre-commit` + `gitleaks` + `detect-private-key` ([`install-guardrails`](skills/install-guardrails/SKILL.md)) | Commits containing secrets or private keys before they enter local git history. |
| **3. Server / CI** | GitHub Actions ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) + audit script ([`scripts/check-github-guardrails.sh`](scripts/check-github-guardrails.sh)) | Unscanned PRs, disabled GitHub Secret Scanning / Push Protection, and unprotected `main` branches. |

Safe templates (`.env.example`, `.env.sample`, `.env.template`), public SSH keys (`*.pub`), and `git push --force-with-lease` remain allowed.

## Installation

### 1. Install the agent plugin

**Claude Code:**

```bash
claude plugin marketplace add LeanoA/agent-secret-guard
claude plugin install agent-secret-guard@agent-secret-guard
```

Or test locally from a clone:

```bash
claude --plugin-dir /path/to/agent-secret-guard
```

**Antigravity CLI:**

Clone into your workspace or global plugins directory (`.agents/plugins/agent-secret-guard` or `~/.gemini/config/plugins/agent-secret-guard`), or install from a local clone:

```bash
agy plugin install /path/to/agent-secret-guard
```

### 2. Add commit guardrails to a repository

Ask Claude Code to run the `install-guardrails` skill, or run the script directly:

```bash
bash skills/install-guardrails/scripts/install.sh /path/to/your-repo
```

The installer refuses to overwrite an existing `.pre-commit-config.yaml`.

### 3. Audit GitHub server-side controls

```bash
bash scripts/check-github-guardrails.sh owner/repo
```

See [`docs/github-guardrails.md`](docs/github-guardrails.md) for setup instructions and [`docs/secret-leak-runbook.md`](docs/secret-leak-runbook.md) for incident response.

## Quick Verification

```bash
# Run the hook and installer test suites (requires bats and jq)
bats tests

# Validate both plugin manifests
claude plugin validate .
agy plugin validate .
```

Example of a blocked tool call:

```bash
# Claude Code payload (exit 2, reason on stderr)
printf '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/repo/.env"}}' \
  | ./hooks/guard.py
# stderr: agent-secret-guard: blocked: Read on secret file '/repo/.env'. Ask the user to handle secrets outside the agent.
# exit code: 2

# Antigravity payload (exit 0, JSON deny on stdout)
printf '{"hookEventName":"PreToolUse","toolCall":{"name":"read_file","args":{"Path":"/repo/.env"}}}' \
  | ./hooks/guard.py
# stdout: {"decision": "deny", "reason": "agent-secret-guard: blocked: read_file on secret file '/repo/.env'. Ask the user to handle secrets outside the agent."}
```

## Known Limitations

- **Shell parsing is heuristic, not a full bash parser.** Obfuscated commands (e.g., `eval`, base64-encoded paths, dynamic variable indirection like `f=.env; cat "$f"`) can evade `hooks/guard.py`. That is why Layer 1 is paired with `pre-commit` (Layer 2) and GitHub Push Protection (Layer 3), and why production secrets should never sit in developer worktrees in the first place.
- **`hooks/guard.py` requires `python3` (stdlib only, no third-party packages).** Malformed JSON payloads and unclosed shell quotes fail closed (exit 2). `scripts/check-github-guardrails.sh` additionally uses `gh` and `jq`.
- **Pre-commit hooks only run when installed** (`pre-commit install`). CI (`gitleaks-action`) and GitHub Push Protection enforce the boundary server-side.

## License

MIT
