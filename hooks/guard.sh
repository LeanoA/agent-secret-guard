#!/usr/bin/env bash
# claude-code-guardrails — PreToolUse hook for Claude Code.
#
# Blocks the agent from reading or editing secret files and from bypassing
# git guardrails (pre-commit hooks, force pushes).
#
# Contract (Claude Code hooks): the payload arrives as JSON on stdin.
#   exit 0 -> allow the tool call
#   exit 2 -> block it; stderr is shown to the agent as the reason
#
# Portable to macOS /bin/bash 3.2: no mapfile, no associative arrays.
set -uo pipefail

block() {
  printf 'claude-code-guardrails: blocked: %s\n' "$1" >&2
  exit 2
}

input=$(cat)
tool=$(printf '%s' "$input" | jq -er '.tool_name' 2>/dev/null) ||
  block "could not parse the hook payload (failing closed)"

# is_secret_path PATH -> status 0 when PATH names a secret file or directory.
is_secret_path() {
  local p="$1" base
  base="${p##*/}"

  case "$p" in
    */.ssh/* | .ssh/*) return 0 ;;
    */.aws/credentials | .aws/credentials) return 0 ;;
    */.config/gcloud/* | .config/gcloud/*) return 0 ;;
  esac

  case "$base" in
    .env.example | .env.sample | .env.template) return 1 ;;
    .env | .env.*) return 0 ;;
    .env[*?[]*) return 0 ;; # glob patterns such as .env* that would match secrets
    *.pub) return 1 ;;
    id_rsa* | id_dsa* | id_ecdsa* | id_ed25519*) return 0 ;;
    *.pem | *.key | *.p12 | *.pfx) return 0 ;;
    .npmrc | .pypirc | credentials.json) return 0 ;;
    *service-account*.json | *service_account*.json) return 0 ;;
  esac
  return 1
}

# check_bash_secrets CMD -> blocks when any word of CMD names a secret file.
check_bash_secrets() {
  local words tok
  # Shell punctuation and quotes become separators: `cat ".env"`, `<~/.ssh/id_rsa`.
  words=$(printf '%s' "$1" | tr ';|&<>()`"'"'"'=' '            ')
  set -f
  for tok in $words; do
    if is_secret_path "$tok"; then
      set +f
      block "command references secret file '$tok'. Ask the user to handle secrets outside the agent."
    fi
  done
  set +f
}

# check_git_segment SEGMENT -> blocks git hook bypasses and force pushes.
check_git_segment() {
  local -a t
  local i n sub="" skip_next=0 tok
  set -f
  # shellcheck disable=SC2206 # intentional word splitting, globbing disabled
  t=($1)
  set +f
  n=${#t[@]}

  for ((i = 0; i < n; i++)); do
    [ "${t[i]}" = "git" ] && break
  done
  [ "$i" -lt "$n" ] || return 0

  # Find the subcommand, skipping git's global options.
  for ((i = i + 1; i < n; i++)); do
    tok="${t[i]}"
    if [ "$skip_next" -eq 1 ]; then
      skip_next=0
      [[ "$tok" == core.hooksPath=* || "$tok" == core.hookspath=* ]] &&
        block "overriding core.hooksPath disables the repository's git hooks."
      continue
    fi
    case "$tok" in
      -C | -c) skip_next=1 ;;
      -*) ;;
      *) sub="$tok"; break ;;
    esac
  done

  case "$sub" in
    commit | push) ;;
    *) return 0 ;;
  esac

  for ((i = i + 1; i < n; i++)); do
    tok="${t[i]}"
    case "$tok" in
      --no-verify)
        block "'git $sub --no-verify' skips the repository's git hooks. Fix the hook failure instead." ;;
      --force)
        [ "$sub" = "push" ] &&
          block "force push rewrites shared history. Use --force-with-lease if you really need it." ;;
      --*) ;;
      -*)
        if [ "$sub" = "commit" ] && [[ "$tok" == *n* ]]; then
          block "'git commit -n' skips the repository's git hooks. Fix the hook failure instead."
        fi
        if [ "$sub" = "push" ] && [[ "$tok" == *f* ]]; then
          block "force push rewrites shared history. Use --force-with-lease if you really need it."
        fi
        ;;
      +*)
        [ "$sub" = "push" ] &&
          block "force-push refspec '$tok' rewrites shared history."
        ;;
    esac
  done
}

check_bash_git() {
  local cmd segment
  # Drop quoted strings (commit messages) so their contents are not read as flags.
  cmd=$(printf '%s' "$1" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")
  while IFS= read -r segment; do
    check_git_segment "$segment"
  done < <(printf '%s\n' "$cmd" | tr ';|&' '\n\n\n')
}

case "$tool" in
  Read | Edit | Write | MultiEdit | NotebookEdit | Grep | Glob)
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      is_secret_path "$path" &&
        block "$tool on secret file '$path'. Ask the user to handle secrets outside the agent."
    done < <(printf '%s' "$input" | jq -r --arg tool "$tool" '
      .tool_input
      | [.file_path, .notebook_path, .path, .glob,
         (if $tool == "Glob" then .pattern else null end)]
      | .[] | select(type == "string")')
    ;;
  Bash)
    command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
    check_bash_secrets "$command"
    check_bash_git "$command"
    ;;
esac

exit 0
