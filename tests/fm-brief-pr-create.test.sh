#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=

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

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-brief-pr-create-tests.XXXXXX")

test_direct_pr_brief_uses_guarded_pr_creation() {
  local home brief
  home="$TMP_ROOT/direct-pr-home"
  mkdir -p "$home/data"
  printf '%s\n' '- alpha [direct-PR] - test project (added 2026-06-26)' > "$home/data/projects.md"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" task-guard alpha >/dev/null
  brief="$home/data/task-guard/brief.md"

  grep -F 'Before any PR creation, run the pr-readiness audit' "$brief" >/dev/null || fail "direct-PR brief does not require pr-readiness"
  grep -F 'open a GitHub PR only through ' "$brief" >/dev/null || fail "direct-PR brief does not require guarded PR creation"
  grep -F 'bin/fm-pr-create.sh' "$brief" >/dev/null || fail "direct-PR brief omits fm-pr-create.sh"
  grep -F "never through gh-axi pr create directly" "$brief" >/dev/null || fail "direct-PR brief does not ban direct gh-axi PR creation"
  grep -F 'If those approval values are absent or the guard refuses, do NOT push, do NOT open a PR, and do NOT merge.' "$brief" >/dev/null \
    || fail "direct-PR brief does not define no-approval fallback"
  pass "direct-PR brief uses guarded PR creation and local-review fallback"
}

test_direct_pr_brief_uses_guarded_pr_creation
