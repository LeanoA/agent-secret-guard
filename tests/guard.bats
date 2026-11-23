#!/usr/bin/env bats
# Tests for hooks/guard.py: the PreToolUse hook that blocks agent access to
# secret files (S2) and git guardrail bypasses (S3).

GUARD="$BATS_TEST_DIRNAME/../hooks/guard.py"

# Build a PreToolUse payload: tool name + tool_input JSON object.
payload() {
  jq -cn --arg tool "$1" --argjson input "$2" \
    '{hook_event_name: "PreToolUse", cwd: "/repo", tool_name: $tool, tool_input: $input}'
}

run_guard() {
  run bash -c 'printf "%s" "$1" | "$2"' _ "$(payload "$1" "$2")" "$GUARD"
}

assert_blocked() {
  [ "$status" -eq 2 ] || { echo "expected exit 2, got $status: $output"; return 1; }
  [[ "$output" == *"agent-secret-guard"* ]] || { echo "missing reason: $output"; return 1; }
}

assert_allowed() {
  [ "$status" -eq 0 ] || { echo "expected exit 0, got $status: $output"; return 1; }
  [ -z "$output" ] || { echo "expected no output, got: $output"; return 1; }
}

# --- S2: file tools on secret files -----------------------------------------

@test "S2: Read .env is blocked" {
  run_guard Read '{"file_path": "/repo/.env"}'
  assert_blocked
}

@test "S2: Read .env.production is blocked" {
  run_guard Read '{"file_path": "/repo/config/.env.production"}'
  assert_blocked
}

@test "S2: Edit private key .pem is blocked" {
  run_guard Edit '{"file_path": "/repo/certs/server.pem", "old_string": "a", "new_string": "b"}'
  assert_blocked
}

@test "S2: Write .key file is blocked" {
  run_guard Write '{"file_path": "/repo/tls/server.key", "content": "x"}'
  assert_blocked
}

@test "S2: MultiEdit .npmrc is blocked" {
  run_guard MultiEdit '{"file_path": "/home/u/.npmrc", "edits": []}'
  assert_blocked
}

@test "S2: NotebookEdit on secret path is blocked" {
  run_guard NotebookEdit '{"notebook_path": "/repo/.env", "new_source": "x"}'
  assert_blocked
}

@test "S2: Read SSH private key is blocked" {
  run_guard Read '{"file_path": "/home/u/.ssh/id_ed25519"}'
  assert_blocked
}

@test "S2: Read anything under ~/.ssh is blocked" {
  run_guard Read '{"file_path": "/home/u/.ssh/config"}'
  assert_blocked
}

@test "S2: Read AWS credentials is blocked" {
  run_guard Read '{"file_path": "/home/u/.aws/credentials"}'
  assert_blocked
}

@test "S2: Read gcloud config is blocked" {
  run_guard Read '{"file_path": "/home/u/.config/gcloud/application_default_credentials.json"}'
  assert_blocked
}

@test "S2: Read service account JSON is blocked" {
  run_guard Read '{"file_path": "/repo/deploy/my-service-account-key.json"}'
  assert_blocked
}

@test "S2: Read credentials.json is blocked" {
  run_guard Read '{"file_path": "/repo/credentials.json"}'
  assert_blocked
}

@test "S2: Read .pypirc, .p12 and .pfx are blocked" {
  run_guard Read '{"file_path": "/home/u/.pypirc"}'
  assert_blocked
  run_guard Read '{"file_path": "/repo/cert.p12"}'
  assert_blocked
  run_guard Read '{"file_path": "/repo/cert.pfx"}'
  assert_blocked
}

@test "S2: Grep inside .env is blocked" {
  run_guard Grep '{"pattern": "API_KEY", "path": "/repo/.env"}'
  assert_blocked
}

@test "S2: Glob for .env files is blocked" {
  run_guard Glob '{"pattern": "**/.env*"}'
  assert_blocked
}

@test "S2: Read .env.example is allowed" {
  run_guard Read '{"file_path": "/repo/.env.example"}'
  assert_allowed
}

@test "S2: Read .env.sample and .env.template are allowed" {
  run_guard Read '{"file_path": "/repo/.env.sample"}'
  assert_allowed
  run_guard Read '{"file_path": "/repo/.env.template"}'
  assert_allowed
}

@test "S2: Read public SSH key is allowed (including inside ~/.ssh)" {
  run_guard Read '{"file_path": "/repo/keys/id_ed25519.pub"}'
  assert_allowed
  run_guard Read '{"file_path": "/home/u/.ssh/id_ed25519.pub"}'
  assert_allowed
}

@test "S2: Grep and Glob on secret directories without trailing slash are blocked" {
  run_guard Grep '{"pattern": "PRIVATE", "path": "/home/u/.ssh"}'
  assert_blocked
  run_guard Grep '{"pattern": "token", "path": "/home/u/.config/gcloud"}'
  assert_blocked
  run_guard Grep '{"pattern": "key", "path": "/home/u/.aws"}'
  assert_blocked
  run_guard Glob '{"pattern": "*", "path": "/home/u/.ssh"}'
  assert_blocked
  run_guard Bash '{"command": "grep -r PRIVATE ~/.ssh"}'
  assert_blocked
}

@test "S2: normalized . / .. paths, brace expansion, and wildcard globs are blocked" {
  run_guard Read '{"file_path": "~/.aws/./credentials"}'
  assert_blocked
  run_guard Read '{"file_path": "~/.aws/sub/../credentials"}'
  assert_blocked
  run_guard Read '{"file_path": "~/.aws/."}'
  assert_blocked
  run_guard Read '{"file_path": "~/.config/./gcloud"}'
  assert_blocked
  run_guard Bash '{"command": "cat {.env,.env.example}"}'
  assert_blocked
  run_guard Glob '{"pattern": "*.env"}'
  assert_blocked
  run_guard Glob '{"pattern": "**/.aws/*"}'
  assert_blocked
}

@test "S2: git commit message mentioning .env is allowed, but command substitution is blocked" {
  run_guard Bash '{"command": "git commit -m \"fix .env parsing\""}'
  assert_allowed
  run_guard Bash '{"command": "git commit -m \"$(cat .env)\""}'
  assert_blocked
}

@test "S2: Read ordinary source file is allowed" {
  run_guard Read '{"file_path": "/repo/src/environment.py"}'
  assert_allowed
}

# --- S2: Bash commands referencing secret files -----------------------------

@test "S2: Bash cat .env is blocked" {
  run_guard Bash '{"command": "cat .env"}'
  assert_blocked
}

@test "S2: Bash source ./config/.env.local is blocked" {
  run_guard Bash '{"command": "source ./config/.env.local && npm start"}'
  assert_blocked
}

@test "S2: Bash reading SSH key via redirect is blocked" {
  run_guard Bash '{"command": "base64 <~/.ssh/id_rsa"}'
  assert_blocked
}

@test "S2: Bash cp .env.example .env is blocked (writes a secret file)" {
  run_guard Bash '{"command": "cp .env.example .env"}'
  assert_blocked
}

@test "S2: Bash cat .env.example is allowed" {
  run_guard Bash '{"command": "cat .env.example"}'
  assert_allowed
}

@test "S2: Bash ordinary command is allowed" {
  run_guard Bash '{"command": "pytest tests/ -q && git status"}'
  assert_allowed
}

# --- S3: git guardrail bypasses ---------------------------------------------

@test "S3: git commit --no-verify is blocked" {
  run_guard Bash '{"command": "git commit --no-verify -m \"wip\""}'
  assert_blocked
}

@test "S3: git commit -n is blocked" {
  run_guard Bash '{"command": "git commit -n -m wip"}'
  assert_blocked
}

@test "S3: git commit with combined short flags including n is blocked" {
  run_guard Bash '{"command": "git commit -anm wip"}'
  assert_blocked
}

@test "S3: git push --no-verify is blocked" {
  run_guard Bash '{"command": "git push --no-verify origin feat"}'
  assert_blocked
}

@test "S3: git push --force is blocked" {
  run_guard Bash '{"command": "git push --force origin main"}'
  assert_blocked
}

@test "S3: git push -f is blocked" {
  run_guard Bash '{"command": "git add . && git push -f"}'
  assert_blocked
}

@test "S3: git push origin +main (force refspec) is blocked" {
  run_guard Bash '{"command": "git push origin +main"}'
  assert_blocked
}

@test "S3: git push --force-with-lease is allowed" {
  run_guard Bash '{"command": "git push --force-with-lease origin feat"}'
  assert_allowed
}

@test "S3: plain git commit and push are allowed" {
  run_guard Bash '{"command": "git commit -m \"feat: add x\" && git push origin feat"}'
  assert_allowed
}

@test "S3: commit message containing -n or --no-verify text is allowed" {
  run_guard Bash '{"command": "git commit -m \"docs: explain why --no-verify and -n are blocked\""}'
  assert_allowed
}

@test "S3: git -c core.hooksPath=/dev/null commit is blocked" {
  run_guard Bash '{"command": "git -c core.hooksPath=/dev/null commit -m wip"}'
  assert_blocked
}

@test "S3: git -C other/repo commit --no-verify is blocked" {
  run_guard Bash '{"command": "git -C other/repo commit --no-verify -m wip"}'
  assert_blocked
}

@test "S3: attached -c and mixed-case core.HooksPath are blocked" {
  run_guard Bash '{"command": "git -ccore.hooksPath=/dev/null commit -m wip"}'
  assert_blocked
  run_guard Bash '{"command": "git -c core.HooksPath=/dev/null commit -m wip"}'
  assert_blocked
}

@test "S3: --git-dir, --work-tree, --config-env, and full-path /usr/bin/git cannot bypass guardrails" {
  run_guard Bash '{"command": "git --git-dir .git commit --no-verify -m wip"}'
  assert_blocked
  run_guard Bash '{"command": "git --git-dir=.git commit --no-verify -m wip"}'
  assert_blocked
  run_guard Bash '{"command": "git --work-tree . commit --no-verify -m wip"}'
  assert_blocked
  run_guard Bash '{"command": "git --config-env=core.hooksPath=HOOK_ENV commit -m wip"}'
  assert_blocked
  run_guard Bash '{"command": "/usr/bin/git commit --no-verify -m wip"}'
  assert_blocked
}

@test "S3: multiline command cannot bypass guardrails and unclosed quote fails closed" {
  run_guard Bash '{"command": "echo ok\ngit commit --no-verify -m wip"}'
  assert_blocked
  run_guard Bash '{"command": "git commit \\\n --no-verify -m wip"}'
  assert_blocked
  run_guard Bash '{"command": "git commit -m \"unclosed"}'
  assert_blocked
}

@test "S3: env /git prefix, backticks, bash -c, --no-veri, and GIT_CONFIG env vars are blocked" {
  run_guard Bash '{"command": "env FOO=/usr/bin/git git commit --no-verify"}'
  assert_blocked
  run_guard Bash '{"command": "echo `git commit --no-verify -m wip`"}'
  assert_blocked
  run_guard Bash '{"command": "bash -c '\''git commit --no-verify -m wip'\''"}'
  assert_blocked
  run_guard Bash '{"command": "git commit --no-veri -m wip"}'
  assert_blocked
  run_guard Bash '{"command": "GIT_CONFIG_PARAMETERS=\"\x27core.hooksPath=/dev/null\x27\" git commit -m wip"}'
  assert_blocked
  run_guard Bash '{"command": "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m wip"}'
  assert_blocked
}

@test "S3: git push -oforce (push-option) does not false-positive as -f" {
  run_guard Bash '{"command": "git push -oforce origin main"}'
  assert_allowed
}

@test "S3: quoted flags and refspecs are still blocked" {
  run_guard Bash '{"command": "git -c \"core.hooksPath=/dev/null\" commit -m wip"}'
  assert_blocked
  run_guard Bash '{"command": "git push origin \"+main\""}'
  assert_blocked
  run_guard Bash '{"command": "git commit \"--no-verify\" -m wip"}'
  assert_blocked
  run_guard Bash '{"command": "git push \"--force\" origin main"}'
  assert_blocked
}

@test "S3: escaped quotes inside commit message do not false-positive" {
  run_guard Bash '{"command": "git commit -m \"docs: mention \\\"-n\\\"\""}'
  assert_allowed
  run_guard Bash '{"command": "git commit -am \"docs: mention --no-verify\""}'
  assert_allowed
}

# --- Robustness --------------------------------------------------------------

@test "unknown tools are allowed" {
  run_guard WebFetch '{"url": "https://example.com/.env"}'
  assert_allowed
}

@test "malformed JSON fails closed" {
  run bash -c 'printf "not json" | "$1"' _ "$GUARD"
  assert_blocked
}

# --- Antigravity CLI PreToolUse contract ------------------------------------

agy_payload() {
  jq -cn --arg name "$1" --argjson args "$2" \
    '{hookEventName: "PreToolUse", cwd: "/repo", toolCall: {id: "toolu_01", name: $name, args: $args}}'
}

run_agy_guard() {
  run bash -c 'printf "%s" "$1" | "$2"' _ "$(agy_payload "$1" "$2")" "$GUARD"
}

assert_agy_denied() {
  [ "$status" -eq 0 ] || { echo "expected exit 0, got $status: $output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "deny" ] || { echo "expected deny, got: $output"; return 1; }
  [[ "$(printf '%s' "$output" | jq -r '.reason')" == *"agent-secret-guard"* ]]
}

assert_agy_allowed() {
  [ "$status" -eq 0 ] || { echo "expected exit 0, got $status: $output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "allow" ] || { echo "expected allow, got: $output"; return 1; }
}

@test "AGY: read_file and write_file on secret files are denied" {
  run_agy_guard read_file '{"Path": "/repo/.env"}'
  assert_agy_denied
  run_agy_guard write_file '{"Path": "/repo/tls/server.key", "Content": "x"}'
  assert_agy_denied
  run_agy_guard edit_file '{"Path": "/home/u/.aws/./credentials"}'
  assert_agy_denied
}

@test "AGY: read_file on .env.example and ~/.ssh/*.pub are allowed" {
  run_agy_guard read_file '{"Path": "/repo/.env.example"}'
  assert_agy_allowed
  run_agy_guard read_file '{"Path": "/home/u/.ssh/id_ed25519.pub"}'
  assert_agy_allowed
}

@test "AGY: find_by_name and grep_search enforce secret globs without flagging search Query" {
  run_agy_guard find_by_name '{"SearchDirectory": "/repo", "Pattern": "**/.env*"}'
  assert_agy_denied
  run_agy_guard grep_search '{"SearchPath": "/repo", "Includes": ["*.env"], "Query": "SECRET"}'
  assert_agy_denied
  run_agy_guard grep_search '{"SearchPath": "/repo/src", "Query": ".env"}'
  assert_agy_allowed
}

@test "AGY: run_command blocks secret reads and git guardrail bypasses" {
  run_agy_guard run_command '{"CommandLine": "cat .env"}'
  assert_agy_denied
  run_agy_guard run_command '{"CommandLine": "git commit --no-veri -m wip"}'
  assert_agy_denied
  run_agy_guard run_command '{"CommandLine": "git push --force origin main"}'
  assert_agy_denied
  run_agy_guard run_command '{"CommandLine": "pytest tests/ -q && git status"}'
  assert_agy_allowed
}

@test "AGY: unknown tools are allowed and malformed toolCall denies" {
  run_agy_guard ask_question '{"questions": []}'
  assert_agy_allowed
  run bash -c 'printf "%s" "{\"hookEventName\":\"PreToolUse\",\"toolCall\":\"bad\"}" | "$1"' _ "$GUARD"
  assert_agy_denied
}
