#!/usr/bin/env bash
# Read-only audit of GitHub server-side guardrails for a repository.
#
# Usage: check-github-guardrails.sh OWNER/REPO
# Requires: gh (authenticated) and jq.
# Exit 0 when all checked controls are enabled, 1 when any control is off/missing, 2 on usage error.
set -euo pipefail

if [ "$#" -ne 1 ] || [[ "$1" != */* ]]; then
  echo "usage: $0 OWNER/REPO" >&2
  exit 2
fi

repo="$1"
fail=0

report() {
  printf '%-28s %s\n' "$1" "$2"
  [ "$2" = "PASS" ] || fail=1
}

meta=$(gh api "repos/$repo" 2>/dev/null) || {
  echo "error: could not fetch repos/$repo via gh api" >&2
  exit 2
}

default_branch=$(printf '%s' "$meta" | jq -r '.default_branch // "main"')
sec_scan=$(printf '%s' "$meta" | jq -r '.security_and_analysis.secret_scanning.status // "unknown"')
push_prot=$(printf '%s' "$meta" | jq -r '.security_and_analysis.secret_scanning_push_protection.status // "unknown"')

[ "$sec_scan" = "enabled" ] && report "secret_scanning" "PASS" || report "secret_scanning" "FAIL ($sec_scan)"
[ "$push_prot" = "enabled" ] && report "push_protection" "PASS" || report "push_protection" "FAIL ($push_prot)"

if gh api "repos/$repo/branches/$default_branch/protection" >/dev/null 2>&1; then
  report "branch_protection($default_branch)" "PASS"
else
  rulesets=$(gh api "repos/$repo/rules/branches/$default_branch" 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
  if [ "${rulesets:-0}" -gt 0 ]; then
    report "branch_rules($default_branch)" "PASS"
  else
    report "branch_protection($default_branch)" "FAIL (none)"
  fi
fi

exit "$fail"
