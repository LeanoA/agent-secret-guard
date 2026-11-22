#!/usr/bin/env bats
# Tests for scripts/check-github-guardrails.sh (S5).

CHECK="$BATS_TEST_DIRNAME/../scripts/check-github-guardrails.sh"

setup() {
  scratch="$(mktemp -d)"
  fakebin="$scratch/bin"
  mkdir -p "$fakebin"
}

teardown() {
  rm -rf "$scratch"
}

make_fake_gh() {
  local sec_scan="$1" push_prot="$2" bp_exit="$3" rules_json="$4"
  cat >"$fakebin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "api repos/o/r")
    printf '{"default_branch":"main","security_and_analysis":{"secret_scanning":{"status":"%s"},"secret_scanning_push_protection":{"status":"%s"}}}\n' "$sec_scan" "$push_prot"
    ;;
  "api repos/o/r/branches/main/protection")
    exit $bp_exit
    ;;
  "api repos/o/r/rules/branches/main")
    printf '%s\n' '$rules_json'
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$fakebin/gh"
}

@test "S5: exits 0 when secret scanning, push protection, and branch protection are enabled" {
  make_fake_gh enabled enabled 0 '[]'
  run env PATH="$fakebin:/usr/bin:/bin" bash "$CHECK" o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"secret_scanning"*PASS* ]]
  [[ "$output" == *"push_protection"*PASS* ]]
  [[ "$output" == *"branch_protection(main)"*PASS* ]]
}

@test "S5: exits 0 when branch ruleset protects main" {
  make_fake_gh enabled enabled 1 '[{"type":"pull_request"}]'
  run env PATH="$fakebin:/usr/bin:/bin" bash "$CHECK" o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"branch_rules(main)"*PASS* ]]
}

@test "S5: exits 1 when push protection or branch protection is disabled" {
  make_fake_gh enabled disabled 1 '[]'
  run env PATH="$fakebin:/usr/bin:/bin" bash "$CHECK" o/r
  [ "$status" -eq 1 ]
  [[ "$output" == *"push_protection"*FAIL* ]]
  [[ "$output" == *"branch_protection(main)"*FAIL* ]]
}

@test "S5: exits 2 on invalid repo argument" {
  run bash "$CHECK" not-a-slug
  [ "$status" -eq 2 ]
}
