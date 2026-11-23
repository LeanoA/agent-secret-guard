#!/usr/bin/env bash
# agent-secret-guard — PreToolUse hook for AI coding agents (Claude Code format).
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
  printf 'agent-secret-guard: blocked: %s\n' "$1" >&2
  exit 2
}

input=$(cat)
tool=$(printf '%s' "$input" | jq -er '.tool_name' 2>/dev/null) ||
  block "could not parse the hook payload (failing closed)"

# is_secret_path PATH -> status 0 when PATH names a secret file or directory.
is_secret_path() {
  local p="$1" base
  # Normalize trailing slashes so directory paths like ~/.ssh and ~/.ssh/ match alike.
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do
    p="${p%/}"
  done
  base="${p##*/}"

  # Public keys and safe env templates are always allowed.
  case "$base" in
    .env.example | .env.sample | .env.template | *.pub) return 1 ;;
  esac

  case "$p" in
    */.ssh/* | .ssh/* | */.ssh | .ssh) return 0 ;;
    */.aws/credentials | .aws/credentials | */.aws | .aws) return 0 ;;
    */.config/gcloud/* | .config/gcloud/* | */.config/gcloud | .config/gcloud) return 0 ;;
  esac

  case "$base" in
    .env | .env.*) return 0 ;;
    .env[*?[]*) return 0 ;; # glob patterns such as .env* that would match secrets
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

check_git_config_opt() {
  local lower
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    core.hookspath=*)
      block "overriding core.hooksPath disables the repository's git hooks." ;;
  esac
}

# check_git_tokens TOK1 TOK2 ... -> blocks git hook bypasses and force pushes in one segment.
check_git_tokens() {
  local -a t
  t=("$@")
  local i n=${#t[@]} sub="" skip_next=0 tok

  for ((i = 0; i < n; i++)); do
    case "${t[i]}" in
      git | */git) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0

  # Find the subcommand, skipping git's global options.
  for ((i = i + 1; i < n; i++)); do
    tok="${t[i]}"
    if [ "$skip_next" -eq 2 ]; then
      skip_next=0
      check_git_config_opt "$tok"
      continue
    elif [ "$skip_next" -eq 1 ]; then
      skip_next=0
      continue
    fi
    case "$tok" in
      -c) skip_next=2 ;;
      -c*) check_git_config_opt "${tok#-c}" ;;
      -C | --git-dir | --work-tree | --namespace | --super-prefix | --config-env) skip_next=1 ;;
      -*) ;;
      *) sub="$tok"; break ;;
    esac
  done

  case "$sub" in
    commit | push) ;;
    *) return 0 ;;
  esac

  local skip_arg=0
  for ((i = i + 1; i < n; i++)); do
    tok="${t[i]}"
    if [ "$skip_arg" -eq 1 ]; then
      skip_arg=0
      continue
    fi
    case "$tok" in
      --no-verify)
        block "'git $sub --no-verify' skips the repository's git hooks. Fix the hook failure instead." ;;
      --force)
        [ "$sub" = "push" ] &&
          block "force push rewrites shared history. Use --force-with-lease if you really need it." ;;
      -m | --message | -F | --file | -C | --reuse-message | -c | --reedit-message | --author | --date | --trailer | -o | --push-option | --receive-pack | --exec)
        skip_arg=1 ;;
      -m* | -F* | --*) ;;
      -*)
        if [ "$sub" = "commit" ] && [[ "$tok" == *n* ]]; then
          block "'git commit -n' skips the repository's git hooks. Fix the hook failure instead."
        fi
        if [ "$sub" = "push" ] && [[ "$tok" == *f* ]]; then
          block "force push rewrites shared history. Use --force-with-lease if you really need it."
        fi
        # Short flag bundle ending in m (e.g. -am "msg") consumes the next token.
        if [ "$sub" = "commit" ] && [[ "$tok" == *m ]]; then
          skip_arg=1
        fi
        ;;
      +*)
        [ "$sub" = "push" ] &&
          block "force-push refspec '$tok' rewrites shared history."
        ;;
    esac
  done
}

# tokenize_shell CMD -> emits one unquoted token per line, with __SEG__ between commands.
# Respects single quotes, double quotes, and backslash escapes so quoted flags like
# "--no-verify" are still inspected while -m "docs: mention \"-n\"" stays a single arg.
tokenize_shell() {
  awk '
    BEGIN { sep = "__SEG__" }
    {
      s = (NR > 1 ? s "\n" $0 : $0)
    }
    END {
      n = length(s)
      q = ""
      tok = ""
      in_tok = 0
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (q == "\047") {
          if (c == "\047") { q = "" }
          else { tok = tok (c == "\n" ? " " : c) }
        } else if (q == "\"") {
          if (c == "\\" && i < n) {
            i++
            nc = substr(s, i, 1)
            tok = tok (nc == "\n" ? " " : nc)
          } else if (c == "\"") {
            q = ""
          } else {
            tok = tok (c == "\n" ? " " : c)
          }
        } else {
          if (c == "\\" && i < n) {
            i++
            tok = tok substr(s, i, 1)
            in_tok = 1
          } else if (c == "\047" || c == "\"") {
            q = c
            in_tok = 1
          } else if (c == ";" || c == "|" || c == "&" || c == "\n") {
            if (in_tok) { print tok; tok = ""; in_tok = 0 }
            print sep
          } else if (c == " " || c == "\t") {
            if (in_tok) { print tok; tok = ""; in_tok = 0 }
          } else {
            tok = tok c
            in_tok = 1
          }
        }
      }
      if (in_tok) print tok
      print sep
    }
  '
}

check_bash_git() {
  local -a seg=()
  local line
  while IFS= read -r line; do
    if [ "$line" = "__SEG__" ]; then
      if [ "${#seg[@]}" -gt 0 ]; then
        check_git_tokens "${seg[@]}"
        seg=()
      fi
    else
      seg+=("$line")
    fi
  done < <(printf '%s' "$1" | tokenize_shell)
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
