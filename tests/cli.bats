#!/usr/bin/env bats
# Tests for bin/cli.mjs (npx agent-secret-guard CLI installer).

CLI="$BATS_TEST_DIRNAME/../bin/cli.mjs"

setup() {
  scratch="$(mktemp -d)"
  repo="$scratch/repo"
  fakehome="$scratch/home"
  fakebin="$scratch/bin"
  mkdir -p "$repo" "$fakehome" "$fakebin"
  git -C "$repo" init -q

  cat >"$fakebin/pre-commit" <<EOF
#!/usr/bin/env bash
echo "\$PWD \$*" >>"$scratch/pre-commit.log"
EOF
  chmod +x "$fakebin/pre-commit"
}

teardown() {
  rm -rf "$scratch"
}

@test "CLI: default project install sets up Claude Code, Antigravity, and pre-commit" {
  run env PATH="$fakebin:$PATH" HOME="$fakehome" node "$CLI" "$repo"
  [ "$status" -eq 0 ]

  # Claude Code hook + settings + skills
  [ -x "$repo/.claude/hooks/agent-secret-guard.py" ]
  [ -f "$repo/.claude/settings.json" ]
  jq -e '.hooks.PreToolUse | length == 1' "$repo/.claude/settings.json" >/dev/null
  jq -e '.hooks.PreToolUse[0].hooks[0].command == "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/agent-secret-guard.py"' "$repo/.claude/settings.json" >/dev/null
  [ -f "$repo/.claude/skills/install-guardrails/SKILL.md" ]
  [ -x "$repo/.claude/skills/install-guardrails/scripts/install.sh" ]
  [ -f "$repo/.claude/skills/secret-leak-response/SKILL.md" ]
  [ -f "$repo/.claude/skills/secret-leak-response/references/secret-leak-runbook.md" ]

  # Antigravity plugin
  [ -f "$repo/.agents/plugins/agent-secret-guard/plugin.json" ]
  [ -f "$repo/.agents/plugins/agent-secret-guard/hooks.json" ]
  [ -x "$repo/.agents/plugins/agent-secret-guard/hooks/guard.py" ]
  [ -f "$repo/.agents/plugins/agent-secret-guard/skills/install-guardrails/SKILL.md" ]
  [ -f "$repo/.agents/plugins/agent-secret-guard/skills/secret-leak-response/SKILL.md" ]

  # Pre-commit Layer 2
  [ -f "$repo/.pre-commit-config.yaml" ]
  grep -qx "$(cd "$repo" && pwd -P) install" "$scratch/pre-commit.log"

  # Installed hooks actively block .env access
  run bash -c 'printf '\''{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/repo/.env"}}'\'' | "'"$repo"'/.claude/hooks/agent-secret-guard.py"'
  [ "$status" -eq 2 ]

  run bash -c 'printf '\''{"hookEventName":"PreToolUse","toolCall":{"name":"read_file","args":{"Path":"/repo/.env"}}}'\'' | "'"$repo"'/.agents/plugins/agent-secret-guard/hooks/guard.py"'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"decision": "deny"'* ]]
}

@test "CLI: install is idempotent and preserves existing settings.json entries" {
  mkdir -p "$repo/.claude"
  cat >"$repo/.claude/settings.json" <<'EOF'
{
  "model": "sonnet",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "./other-hook.sh"
          }
        ]
      }
    ]
  }
}
EOF

  run env PATH="$fakebin:$PATH" HOME="$fakehome" node "$CLI" "$repo"
  [ "$status" -eq 0 ]

  run env PATH="$fakebin:$PATH" HOME="$fakehome" node "$CLI" "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping config creation"* ]]

  jq -e '.model == "sonnet"' "$repo/.claude/settings.json" >/dev/null
  jq -e '.hooks.PreToolUse | length == 2' "$repo/.claude/settings.json" >/dev/null
  jq -e '.hooks.PreToolUse[0].hooks[0].command == "./other-hook.sh"' "$repo/.claude/settings.json" >/dev/null
  jq -e '.hooks.PreToolUse[1].hooks[0].command == "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/agent-secret-guard.py"' "$repo/.claude/settings.json" >/dev/null
}

@test "CLI: --global installs into user home without touching pre-commit" {
  run env PATH="$fakebin:$PATH" HOME="$fakehome" node "$CLI" --global "$repo"
  [ "$status" -eq 0 ]

  [ -x "$fakehome/.claude/hooks/agent-secret-guard.py" ]
  jq -e '.hooks.PreToolUse[0].hooks[0].command == "~/.claude/hooks/agent-secret-guard.py"' "$fakehome/.claude/settings.json" >/dev/null
  [ -f "$fakehome/.claude/skills/install-guardrails/SKILL.md" ]

  [ -f "$fakehome/.gemini/config/plugins/agent-secret-guard/plugin.json" ]
  [ -f "$fakehome/.gemini/config/plugins/agent-secret-guard/hooks.json" ]
  [ -x "$fakehome/.gemini/config/plugins/agent-secret-guard/hooks/guard.py" ]
  [ -f "$fakehome/.gemini/config/plugins/agent-secret-guard/skills/secret-leak-response/SKILL.md" ]

  [ ! -e "$repo/.pre-commit-config.yaml" ]
  [ ! -e "$repo/.claude" ]
  [ ! -e "$repo/.agents" ]
}

@test "CLI: supports --agent and --only-* component filters" {
  run env PATH="$fakebin:$PATH" HOME="$fakehome" node "$CLI" "$repo" --agent claude-code --only-hooks
  [ "$status" -eq 0 ]
  [ -x "$repo/.claude/hooks/agent-secret-guard.py" ]
  [ ! -e "$repo/.claude/skills" ]
  [ ! -e "$repo/.agents" ]
  [ ! -e "$repo/.pre-commit-config.yaml" ]

  run env PATH="$fakebin:$PATH" HOME="$fakehome" node "$CLI" "$repo" --agent antigravity --only-skills
  [ "$status" -eq 0 ]
  [ -f "$repo/.agents/skills/install-guardrails/SKILL.md" ]
  [ -f "$repo/.agents/skills/secret-leak-response/SKILL.md" ]
  [ ! -e "$repo/.agents/plugins" ]
  [ ! -e "$repo/.pre-commit-config.yaml" ]

  run env PATH="$fakebin:$PATH" HOME="$fakehome" node "$CLI" "$repo" --only-pre-commit
  [ "$status" -eq 0 ]
  [ -f "$repo/.pre-commit-config.yaml" ]
  grep -qx "$(cd "$repo" && pwd -P) install" "$scratch/pre-commit.log"
}

@test "CLI: --yes and -y install non-interactively with defaults" {
  run env PATH="$fakebin:$PATH" HOME="$fakehome" node "$CLI" "$repo" --yes
  [ "$status" -eq 0 ]
  [[ "$output" != *"Proceed with installation"* ]]
  [ -x "$repo/.claude/hooks/agent-secret-guard.py" ]
  [ -f "$repo/.agents/plugins/agent-secret-guard/plugin.json" ]
  [ -f "$repo/.pre-commit-config.yaml" ]
  [[ "$output" == *"Done."* ]]

  run env PATH="$fakebin:$PATH" HOME="$fakehome" node "$CLI" -y --global "$repo"
  [ "$status" -eq 0 ]
  [ -x "$fakehome/.claude/hooks/agent-secret-guard.py" ]
}

@test "CLI: --help documents the interactive wizard and --yes" {
  run node "$CLI" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"interactive wizard"* ]]
  [[ "$output" == *"-y, --yes"* ]]
}
