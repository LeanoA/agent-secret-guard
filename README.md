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

### Quickstart via `npx` (recommended)

Run inside your repository root to install **Layer 1** (hooks + skills for both Claude Code and Antigravity CLI) and **Layer 2** (`.pre-commit-config.yaml` + `pre-commit install`) in one step:

```bash
npx agent-secret-guardrails@latest
```

Useful flags:

```bash
# Install Layer 1 globally (~/.claude and ~/.gemini/config/plugins/agent-secret-guard)
npx agent-secret-guardrails@latest --global

# Target a specific agent or component
npx agent-secret-guardrails@latest --agent claude-code --only-hooks
npx agent-secret-guardrails@latest --agent antigravity --only-skills
npx agent-secret-guardrails@latest --no-pre-commit
```

#### CLI Options Reference

| Flag | Default | Description |
|---|---|---|
| `[target-dir]` / `--target <dir>` | `.` (`cwd`) | Target project directory. |
| `-p`, `--project` | `(default)` | Install into target project (`.claude/`, `.agents/`, `.pre-commit-config.yaml`). |
| `-g`, `--global` | `false` | Install Layer 1 globally into `~/.claude/` and `~/.gemini/config/plugins/agent-secret-guard/`. Skips `pre-commit` unless `--only-pre-commit` is passed. |
| `-a`, `--agent <name>` | `all` | Target agent: `claude-code` (`claude`), `antigravity` (`agy`), or `all`. |
| `--only-hooks` | `false` | Only install Layer 1 `PreToolUse` hooks (`guard.py` + settings/plugin hook config). |
| `--only-skills` | `false` | Only install agent skills (`install-guardrails`, `secret-leak-response`). |
| `--only-pre-commit` | `false` | Only install Layer 2 (`.pre-commit-config.yaml` + `pre-commit install`). |
| `--no-pre-commit` | `false` | Skip Layer 2 (`pre-commit`) during a project install. |
| `-h`, `--help` | — | Show CLI help. |
| `-v`, `--version` | — | Print package version. |

**Files installed per scope:**
- **Claude Code:** `<base>/hooks/agent-secret-guard.py`, upserts `PreToolUse` in `<base>/settings.json` (preserving existing settings), and `<base>/skills/{install-guardrails,secret-leak-response}/` (`<base>` is `<target>/.claude` or `~/.claude`).
- **Antigravity CLI:** native plugin under `<base>/plugins/agent-secret-guard/` (`plugin.json`, `hooks.json`, `hooks/guard.py`, `skills/`), or `<base>/skills/` when `--only-skills` is passed (`<base>` is `<target>/.agents` or `~/.gemini/config`).
- **Git pre-commit (project scope):** `.pre-commit-config.yaml` (never overwrites an existing config) and installs the git hook via `pre-commit install`.

### Alternative: Native plugin / `npx skills` install

**Claude Code plugin:**

```bash
claude plugin marketplace add LeanoA/agent-secret-guard
claude plugin install agent-secret-guard@agent-secret-guard
```

Or test locally from a clone:

```bash
claude --plugin-dir /path/to/agent-secret-guard
```

**Antigravity CLI plugin:**

Clone into your workspace or global plugins directory (`.agents/plugins/agent-secret-guard` or `~/.gemini/config/plugins/agent-secret-guard`), or install from a local clone:

```bash
agy plugin install /path/to/agent-secret-guard
```

**Skills only (`npx skills`):**

```bash
npx skills add LeanoA/agent-secret-guard --skill '*' --copy -y
```

### Add commit guardrails manually to a repository

Ask your agent to run the `install-guardrails` skill, or run the script directly:

```bash
bash skills/install-guardrails/scripts/install.sh /path/to/your-repo
```

The installer refuses to overwrite an existing `.pre-commit-config.yaml`.

### Audit GitHub server-side controls

```bash
bash scripts/check-github-guardrails.sh owner/repo
```

See [`docs/github-guardrails.md`](docs/github-guardrails.md) for setup instructions and [`docs/secret-leak-runbook.md`](docs/secret-leak-runbook.md) for incident response.

## How It Works After Installation (Day-to-Day Usage)

Once installed, **everything runs automatically in the background** — you do not need to run any command manually on every commit:

1. **Agent runtime protection (automatic on every tool call):**
   Every time Claude Code or Antigravity CLI invokes a file, search, or shell tool, the `PreToolUse` hook ([`hooks/guard.py`](hooks/guard.py)) intercepts it before execution. Access to `.env*`, keys, cloud credentials, and git guardrail bypasses (`--no-verify`, `-n`, `--force`, `core.hooksPath`) is blocked automatically with an explanation.
2. **Git commit scanning (automatic on every `git commit`):**
   `pre-commit` runs `gitleaks` and `detect-private-key` against staged changes and aborts the commit if a secret or private key is detected. *(Requires `pre-commit` to be installed on your machine, e.g. `brew install pre-commit` or `pipx install pre-commit`.)*
3. **On-demand agent skills:**
   - **`install-guardrails`**: ask your agent *"add commit guardrails / pre-commit secret scanning to this repo"* when setting up a repository without `.pre-commit-config.yaml`.
   - **`secret-leak-response`**: ask your agent *"a secret leaked, help me rotate it and clean git history"* to follow the incident-response runbook without printing secret values.

## Releasing to npm (CI/CD)

Normal pushes to `main` only run CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)). Releases to npm are triggered only when a new `v*` tag is pushed or a GitHub Release is published, using [`.github/workflows/publish.yml`](.github/workflows/publish.yml) via **Trusted Publishing (OIDC)** with provenance attestation:

```bash
# Bumps package.json, syncs .claude-plugin/plugin.json and .antigravity-plugin/plugin.json,
# creates the release commit + vX.Y.Z tag, and pushes to GitHub to trigger npm publish
npm version patch   # or minor / major
git push origin main --follow-tags
```

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
- **`hooks/guard.py` requires `python3` (stdlib only, no third-party packages).** Malformed JSON payloads and unclosed shell quotes fail closed (exit 2, or JSON `deny` in Antigravity mode). `scripts/check-github-guardrails.sh` additionally uses `gh` and `jq`.
- **Antigravity `PreToolUse` decision semantics:** Antigravity requires a `"decision"` field (`allow`, `deny`, `ask`, or `force_ask`). When no secret or git bypass is detected, `hooks/guard.py` returns `{"decision": "allow"}`; adjust that to `"ask"` if you want Antigravity to still prompt interactively on `run_command`. Note also that `agy plugin validate .` emits one non-fatal warning on `hooks/hooks.json` because that file is only for Claude Code (while Antigravity loads root `hooks.json`).
- **Pre-commit hooks only run when installed** (`pre-commit install`). CI (`gitleaks-action`) and GitHub Push Protection enforce the boundary server-side.

## License

MIT
