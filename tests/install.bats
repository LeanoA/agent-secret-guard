#!/usr/bin/env bats
# Tests for skills/install-guardrails/scripts/install.sh (S4).

INSTALL="$BATS_TEST_DIRNAME/../skills/install-guardrails/scripts/install.sh"
TEMPLATE="$BATS_TEST_DIRNAME/../skills/install-guardrails/templates/pre-commit-config.yaml"

setup() {
  scratch="$(mktemp -d)"
  repo="$scratch/repo"
  fakebin="$scratch/bin"
  mkdir -p "$repo" "$fakebin"
  git -C "$repo" init -q
  # Fake pre-commit that records how it was called.
  cat >"$fakebin/pre-commit" <<EOF
#!/usr/bin/env bash
echo "\$PWD \$*" >>"$scratch/pre-commit.log"
EOF
  chmod +x "$fakebin/pre-commit"
}

teardown() {
  rm -rf "$scratch"
}

@test "S4: installs the template and the git hook into a repo" {
  run env PATH="$fakebin:/usr/bin:/bin" bash "$INSTALL" "$repo"
  [ "$status" -eq 0 ]
  cmp "$TEMPLATE" "$repo/.pre-commit-config.yaml"
  grep -qx "$(cd "$repo" && pwd -P) install" "$scratch/pre-commit.log"
}

@test "S4: refuses to overwrite an existing config" {
  echo "repos: []" >"$repo/.pre-commit-config.yaml"
  run env PATH="$fakebin:/usr/bin:/bin" bash "$INSTALL" "$repo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
  [ "$(cat "$repo/.pre-commit-config.yaml")" = "repos: []" ]
  [ ! -e "$scratch/pre-commit.log" ]
}

@test "S4: rejects a directory that is not a git repository" {
  mkdir "$scratch/plain"
  run env PATH="$fakebin:/usr/bin:/bin" bash "$INSTALL" "$scratch/plain"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a git repository"* ]]
  [ ! -e "$scratch/plain/.pre-commit-config.yaml" ]
}

@test "S4: exits 3 with instructions when pre-commit is unavailable" {
  run env PATH="/usr/bin:/bin" bash "$INSTALL" "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"pre-commit not found"* ]]
  [ -e "$repo/.pre-commit-config.yaml" ]
}

@test "S4: the template scans for secrets and private keys" {
  grep -q "id: gitleaks" "$TEMPLATE"
  grep -q "id: detect-private-key" "$TEMPLATE"
}
