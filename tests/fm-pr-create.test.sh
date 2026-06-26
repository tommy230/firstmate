#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}

trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-create-tests.XXXXXX")

make_fake_gh_axi() {
  local dir=$1 fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_GH_AXI_LOG"
SH
  chmod +x "$fakebin/gh-axi"
  printf '%s\n' "$fakebin"
}

assert_not_called() {
  local log=$1 label=$2
  [ ! -s "$log" ] || fail "$label called gh-axi unexpectedly: $(cat "$log")"
}

test_default_refuses_pr_creation() {
  local case_dir fakebin log out err
  case_dir="$TMP_ROOT/default-refuses"
  mkdir -p "$case_dir"
  fakebin=$(make_fake_gh_axi "$case_dir")
  log="$case_dir/gh-axi.log"
  out="$case_dir/out"
  err="$case_dir/err"
  : > "$log"

  if FM_FAKE_GH_AXI_LOG="$log" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-pr-create.sh" --repo kunchenguid/firstmate --title Test >"$out" 2>"$err"; then
    fail "default guard allowed PR creation"
  fi
  assert_not_called "$log" "default guard"
  grep -F "GitHub PR creation is blocked" "$err" >/dev/null || fail "default guard did not explain blocked PR creation"
  pass "default guard refuses GitHub PR creation"
}

test_approval_requires_exact_target_env() {
  local case_dir fakebin log err
  case_dir="$TMP_ROOT/missing-target"
  mkdir -p "$case_dir"
  fakebin=$(make_fake_gh_axi "$case_dir")
  log="$case_dir/gh-axi.log"
  err="$case_dir/err"
  : > "$log"

  if FM_ALLOW_UPSTREAM_PR=1 FM_FAKE_GH_AXI_LOG="$log" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-pr-create.sh" --repo kunchenguid/firstmate > /dev/null 2>"$err"; then
    fail "guard allowed approval without exact target env"
  fi
  assert_not_called "$log" "missing target guard"
  grep -F "FM_UPSTREAM_PR_TARGET is required" "$err" >/dev/null || fail "guard did not require exact target env"
  pass "upstream approval requires exact target env"
}

test_approval_requires_explicit_cli_or_env_repo() {
  local case_dir fakebin log err
  case_dir="$TMP_ROOT/missing-explicit-repo"
  mkdir -p "$case_dir"
  fakebin=$(make_fake_gh_axi "$case_dir")
  log="$case_dir/gh-axi.log"
  err="$case_dir/err"
  : > "$log"

  if FM_ALLOW_UPSTREAM_PR=1 FM_UPSTREAM_PR_TARGET=kunchenguid/firstmate FM_FAKE_GH_AXI_LOG="$log" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-pr-create.sh" --title Test > /dev/null 2>"$err"; then
    fail "guard allowed approval without explicit target repo"
  fi
  assert_not_called "$log" "missing explicit repo guard"
  grep -F "target repo must be explicit" "$err" >/dev/null || fail "guard did not require explicit target repo"
  pass "upstream approval requires explicit target repo"
}

test_approval_rejects_target_mismatch() {
  local case_dir fakebin log err
  case_dir="$TMP_ROOT/target-mismatch"
  mkdir -p "$case_dir"
  fakebin=$(make_fake_gh_axi "$case_dir")
  log="$case_dir/gh-axi.log"
  err="$case_dir/err"
  : > "$log"

  if FM_ALLOW_UPSTREAM_PR=1 FM_UPSTREAM_PR_TARGET=tommy230/firstmate FM_FAKE_GH_AXI_LOG="$log" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-pr-create.sh" --repo kunchenguid/firstmate > /dev/null 2>"$err"; then
    fail "guard allowed mismatched upstream target"
  fi
  assert_not_called "$log" "target mismatch guard"
  grep -F "does not match approved repo" "$err" >/dev/null || fail "guard did not explain target mismatch"
  pass "upstream approval rejects target mismatch"
}

test_exact_approval_invokes_gh_axi() {
  local case_dir fakebin log
  case_dir="$TMP_ROOT/exact-approval"
  mkdir -p "$case_dir"
  fakebin=$(make_fake_gh_axi "$case_dir")
  log="$case_dir/gh-axi.log"
  : > "$log"

  FM_ALLOW_UPSTREAM_PR=1 \
    FM_UPSTREAM_PR_TARGET=kunchenguid/firstmate \
    FM_FAKE_GH_AXI_LOG="$log" \
    PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-pr-create.sh" --repo kunchenguid/firstmate --title Test >/dev/null 2>&1 \
    || fail "guard rejected exact upstream approval"

  grep -Fx "pr create --repo kunchenguid/firstmate --title Test" "$log" >/dev/null || fail "guard did not invoke gh-axi with pr create"
  pass "exact upstream approval invokes gh-axi pr create"
}

test_exact_approval_accepts_short_repo_flag() {
  local case_dir fakebin log
  case_dir="$TMP_ROOT/short-repo-flag"
  mkdir -p "$case_dir"
  fakebin=$(make_fake_gh_axi "$case_dir")
  log="$case_dir/gh-axi.log"
  : > "$log"

  FM_ALLOW_UPSTREAM_PR=1 \
    FM_UPSTREAM_PR_TARGET=kunchenguid/firstmate \
    FM_FAKE_GH_AXI_LOG="$log" \
    PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-pr-create.sh" -R kunchenguid/firstmate --draft >/dev/null 2>&1 \
    || fail "guard rejected exact approval with -R"

  grep -Fx "pr create -R kunchenguid/firstmate --draft" "$log" >/dev/null || fail "guard did not pass through -R invocation"
  pass "exact upstream approval accepts -R target"
}

test_exact_approval_accepts_gh_repo_env_target() {
  local case_dir fakebin log
  case_dir="$TMP_ROOT/gh-repo-env"
  mkdir -p "$case_dir"
  fakebin=$(make_fake_gh_axi "$case_dir")
  log="$case_dir/gh-axi.log"
  : > "$log"

  FM_ALLOW_UPSTREAM_PR=1 \
    FM_UPSTREAM_PR_TARGET=kunchenguid/firstmate \
    GH_REPO=kunchenguid/firstmate \
    FM_FAKE_GH_AXI_LOG="$log" \
    PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-pr-create.sh" --draft >/dev/null 2>&1 \
    || fail "guard rejected exact approval with GH_REPO"

  grep -Fx "pr create --draft" "$log" >/dev/null || fail "guard did not pass through GH_REPO invocation"
  pass "exact upstream approval accepts GH_REPO target"
}

test_compact_short_repo_flag_is_refused() {
  local case_dir fakebin log err
  case_dir="$TMP_ROOT/compact-repo-flag"
  mkdir -p "$case_dir"
  fakebin=$(make_fake_gh_axi "$case_dir")
  log="$case_dir/gh-axi.log"
  err="$case_dir/err"
  : > "$log"

  if FM_ALLOW_UPSTREAM_PR=1 FM_UPSTREAM_PR_TARGET=kunchenguid/firstmate FM_FAKE_GH_AXI_LOG="$log" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-pr-create.sh" -Rkunchenguid/firstmate > /dev/null 2>"$err"; then
    fail "guard allowed compact -R target"
  fi
  assert_not_called "$log" "compact -R guard"
  grep -F "compact -Rowner/repo is refused" "$err" >/dev/null || fail "guard did not explain compact -R refusal"
  pass "compact -R target is refused"
}

test_duplicate_repo_flags_must_all_match() {
  local case_dir fakebin log err
  case_dir="$TMP_ROOT/duplicate-repo-flags"
  mkdir -p "$case_dir"
  fakebin=$(make_fake_gh_axi "$case_dir")
  log="$case_dir/gh-axi.log"
  err="$case_dir/err"
  : > "$log"

  if FM_ALLOW_UPSTREAM_PR=1 FM_UPSTREAM_PR_TARGET=kunchenguid/firstmate FM_FAKE_GH_AXI_LOG="$log" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-pr-create.sh" --repo kunchenguid/firstmate --repo tommy230/firstmate > /dev/null 2>"$err"; then
    fail "guard allowed duplicate repo flag mismatch"
  fi
  assert_not_called "$log" "duplicate repo guard"
  grep -F "target repo 'tommy230/firstmate' does not match approved repo 'kunchenguid/firstmate'" "$err" >/dev/null \
    || fail "guard did not report duplicate repo mismatch"
  pass "duplicate repo flags must all match approval"
}

test_cli_repo_and_gh_repo_must_both_match() {
  local case_dir fakebin log err
  case_dir="$TMP_ROOT/cli-and-env-repo-mismatch"
  mkdir -p "$case_dir"
  fakebin=$(make_fake_gh_axi "$case_dir")
  log="$case_dir/gh-axi.log"
  err="$case_dir/err"
  : > "$log"

  if FM_ALLOW_UPSTREAM_PR=1 FM_UPSTREAM_PR_TARGET=kunchenguid/firstmate GH_REPO=tommy230/firstmate FM_FAKE_GH_AXI_LOG="$log" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-pr-create.sh" --repo kunchenguid/firstmate > /dev/null 2>"$err"; then
    fail "guard allowed GH_REPO mismatch beside CLI repo"
  fi
  assert_not_called "$log" "CLI plus GH_REPO guard"
  grep -F "target repo 'tommy230/firstmate' does not match approved repo 'kunchenguid/firstmate'" "$err" >/dev/null \
    || fail "guard did not report GH_REPO mismatch"
  pass "CLI repo and GH_REPO must both match approval"
}

test_argument_terminator_is_refused() {
  local case_dir fakebin log err
  case_dir="$TMP_ROOT/argument-terminator"
  mkdir -p "$case_dir"
  fakebin=$(make_fake_gh_axi "$case_dir")
  log="$case_dir/gh-axi.log"
  err="$case_dir/err"
  : > "$log"

  if FM_ALLOW_UPSTREAM_PR=1 FM_UPSTREAM_PR_TARGET=kunchenguid/firstmate FM_FAKE_GH_AXI_LOG="$log" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-pr-create.sh" --repo kunchenguid/firstmate -- --repo tommy230/firstmate > /dev/null 2>"$err"; then
    fail "guard allowed repo flag after argument terminator"
  fi
  assert_not_called "$log" "argument terminator guard"
  grep -F "argument terminator is refused" "$err" >/dev/null || fail "guard did not explain argument terminator refusal"
  pass "argument terminator is refused"
}

test_default_refuses_pr_creation
test_approval_requires_exact_target_env
test_approval_requires_explicit_cli_or_env_repo
test_approval_rejects_target_mismatch
test_exact_approval_invokes_gh_axi
test_exact_approval_accepts_short_repo_flag
test_exact_approval_accepts_gh_repo_env_target
test_compact_short_repo_flag_is_refused
test_duplicate_repo_flags_must_all_match
test_cli_repo_and_gh_repo_must_both_match
test_argument_terminator_is_refused
