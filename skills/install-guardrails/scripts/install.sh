#!/usr/bin/env bash
# Install git commit guardrails (pre-commit + gitleaks) into a target repository.
#
# Usage: install.sh [TARGET_REPO]   (defaults to the current directory)
#
# - Copies templates/pre-commit-config.yaml to TARGET/.pre-commit-config.yaml.
#   Never overwrites an existing config: merge it by hand instead.
# - Installs the git hook with `pre-commit install` (or `uvx pre-commit install`).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template="$here/../templates/pre-commit-config.yaml"
target="${1:-.}"

if ! git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: '$target' is not a git repository" >&2
  exit 1
fi
root="$(git -C "$target" rev-parse --show-toplevel)"
config="$root/.pre-commit-config.yaml"

if [ -e "$config" ]; then
  echo "error: $config already exists; merge the hooks from $template by hand" >&2
  exit 1
fi

cp "$template" "$config"
echo "created $config"

if command -v pre-commit >/dev/null 2>&1; then
  (cd "$root" && pre-commit install)
elif command -v uvx >/dev/null 2>&1; then
  (cd "$root" && uvx pre-commit install)
else
  echo "warning: pre-commit not found; install it (pipx install pre-commit) and run 'pre-commit install' in $root" >&2
  exit 3
fi
