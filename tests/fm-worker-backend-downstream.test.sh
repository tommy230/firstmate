#!/usr/bin/env bash
# Backend-aware downstream worker command tests.
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

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-worker-backend-downstream.XXXXXX")

make_fake_tmux() {
  local dir=$1 fakebin log
  fakebin="$dir/fakebin"
  log="$dir/tmux.log"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "${1:-}" in
  list-windows)
    if [ -n "${FM_FAKE_TMUX_WINDOWS:-}" ]; then
      printf '%s\n' "$FM_FAKE_TMUX_WINDOWS"
    fi
    exit 0
    ;;
  capture-pane)
    printf '%s\n' "${FM_FAKE_TMUX_CAPTURE-pane output}"
    exit 0
    ;;
  display-message)
    case " $* " in
      *'#{cursor_y}'*) printf '0\n' ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0
    ;;
  send-keys|kill-window)
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  : > "$log"
  printf '%s\n' "$fakebin"
}

make_home() {
  local home=$1
  mkdir -p "$home/state" "$home/data"
  touch "$home/state/.last-watcher-beat"
}

test_legacy_meta_still_resolves_to_tmux_window() {
  local home fakebin log out
  home="$TMP_ROOT/legacy-home"
  make_home "$home"
  cat > "$home/state/legacy.meta" <<'EOF'
window=current-session:fm-legacy
worker_id=wrong-session:fm-legacy
kind=ship
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/legacy-fake")
  log="$TMP_ROOT/legacy-fake/tmux.log"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="legacy pane" \
    "$ROOT/bin/fm-peek.sh" fm-legacy 5 2>&1) \
    || fail "fm-peek failed for legacy tmux metadata: $out"

  printf '%s\n' "$out" | grep -Fx 'legacy pane' >/dev/null \
    || fail "fm-peek did not return captured pane output"
  grep -F 'capture-pane -p -t current-session:fm-legacy -S -5' "$log" >/dev/null \
    || fail "fm-peek did not target the metadata window"
  pass "legacy metadata without backend still resolves as tmux-treehouse"
}

test_window_metadata_is_preferred_for_tmux_targets() {
  local home fakebin log
  home="$TMP_ROOT/window-priority-home"
  make_home "$home"
  cat > "$home/state/priority.meta" <<'EOF'
backend=tmux-treehouse
window=owned-session:fm-priority
worker_id=wrong-session:fm-priority
kind=ship
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/window-priority-fake")
  log="$TMP_ROOT/window-priority-fake/tmux.log"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="" \
    "$ROOT/bin/fm-send.sh" fm-priority 'route this work' >/dev/null 2>&1 \
    || fail "fm-send failed for tmux-treehouse metadata with worker_id"

  grep -F 'send-keys -t owned-session:fm-priority -l route this work' "$log" >/dev/null \
    || fail "fm-send did not prefer window= for tmux target"
  grep -F 'send-keys -t wrong-session:fm-priority' "$log" >/dev/null \
    && fail "fm-send incorrectly preferred worker_id= over window="
  pass "tmux target resolution prefers window metadata"
}

test_send_rejects_codex_desktop_meta_before_tmux() {
  local home fakebin log err status
  home="$TMP_ROOT/send-codex-home"
  make_home "$home"
  cat > "$home/state/codex.meta" <<'EOF'
backend=codex-desktop
worker_id=desktop-thread-1
kind=ship
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/send-codex-fake")
  log="$TMP_ROOT/send-codex-fake/tmux.log"
  err="$TMP_ROOT/send-codex-fake/send.err"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" \
    "$ROOT/bin/fm-send.sh" fm-codex 'hello' >/dev/null 2>"$err"
  status=$?

  [ "$status" -ne 0 ] || fail "fm-send accepted codex-desktop metadata"
  grep -F 'backend=codex-desktop' "$err" >/dev/null \
    || fail "fm-send did not explain the unsupported backend"
  [ ! -s "$log" ] || fail "fm-send touched tmux for codex-desktop metadata"
  pass "fm-send rejects codex-desktop metadata before tmux side effects"
}

test_direct_session_target_still_uses_tmux() {
  local home fakebin log
  home="$TMP_ROOT/direct-home"
  make_home "$home"
  fakebin=$(make_fake_tmux "$TMP_ROOT/direct-fake")
  log="$TMP_ROOT/direct-fake/tmux.log"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="" \
    "$ROOT/bin/fm-send.sh" other-session:fm-codex 'direct hello' >/dev/null 2>&1 \
    || fail "fm-send failed for explicit session:window target"

  grep -F 'send-keys -t other-session:fm-codex -l direct hello' "$log" >/dev/null \
    || fail "fm-send did not use the explicit session target"
  pass "explicit session:window target still uses raw tmux"
}

test_watch_rejects_codex_desktop_meta_before_tmux() {
  local home fakebin log err status
  home="$TMP_ROOT/watch-codex-home"
  make_home "$home"
  cat > "$home/state/codex.meta" <<'EOF'
backend=codex-desktop
worker_id=desktop-thread-1
kind=ship
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/watch-codex-fake")
  log="$TMP_ROOT/watch-codex-fake/tmux.log"
  err="$TMP_ROOT/watch-codex-fake/watch.err"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_FAKE_TMUX_LOG="$log" \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>"$err"
  status=$?

  [ "$status" -ne 0 ] || fail "fm-watch accepted codex-desktop metadata"
  grep -F 'backend=codex-desktop' "$err" >/dev/null \
    || fail "fm-watch did not explain the unsupported backend"
  [ ! -s "$log" ] || fail "fm-watch touched tmux for codex-desktop metadata"
  pass "fm-watch rejects codex-desktop metadata before tmux side effects"
}

test_teardown_rejects_codex_desktop_meta_before_tmux() {
  local home fakebin log err status
  home="$TMP_ROOT/teardown-codex-home"
  make_home "$home"
  cat > "$home/state/codex.meta" <<'EOF'
backend=codex-desktop
worker_id=desktop-thread-1
kind=ship
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/teardown-codex-fake")
  log="$TMP_ROOT/teardown-codex-fake/tmux.log"
  err="$TMP_ROOT/teardown-codex-fake/teardown.err"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" \
    "$ROOT/bin/fm-teardown.sh" codex >/dev/null 2>"$err"
  status=$?

  [ "$status" -ne 0 ] || fail "fm-teardown accepted codex-desktop metadata"
  grep -F 'backend=codex-desktop' "$err" >/dev/null \
    || fail "fm-teardown did not explain the unsupported backend"
  [ ! -s "$log" ] || fail "fm-teardown touched tmux for codex-desktop metadata"
  [ -f "$home/state/codex.meta" ] || fail "fm-teardown removed unsupported backend metadata"
  pass "fm-teardown rejects codex-desktop metadata before tmux side effects"
}

test_secondmate_force_teardown_rejects_unsupported_child_backend() {
  local home subhome fakebin log err status
  home="$TMP_ROOT/secondmate-child-backend-home"
  subhome="$TMP_ROOT/secondmate-child-backend-subhome"
  make_home "$home"
  mkdir -p "$subhome/state" "$subhome/data" "$subhome/config" "$subhome/projects"
  printf 'parent\n' > "$subhome/.fm-secondmate-home"
  cat > "$home/state/parent.meta" <<EOF
backend=tmux-treehouse
kind=secondmate
window=firstmate:fm-parent
worktree=$subhome
home=$subhome
EOF
  cat > "$subhome/state/child.meta" <<'EOF'
backend=codex-desktop
worker_id=desktop-thread-1
kind=ship
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/secondmate-child-backend-fake")
  log="$TMP_ROOT/secondmate-child-backend-fake/tmux.log"
  err="$TMP_ROOT/secondmate-child-backend-fake/teardown.err"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" \
    "$ROOT/bin/fm-teardown.sh" parent --force >/dev/null 2>"$err"
  status=$?

  [ "$status" -ne 0 ] || fail "secondmate force teardown accepted unsupported child backend"
  grep -F 'backend=codex-desktop' "$err" >/dev/null \
    || fail "secondmate force teardown did not explain unsupported child backend"
  [ ! -s "$log" ] || fail "secondmate force teardown touched tmux before child backend validation"
  [ -f "$home/state/parent.meta" ] || fail "secondmate force teardown removed parent metadata"
  [ -f "$subhome/state/child.meta" ] || fail "secondmate force teardown removed unsupported child metadata"
  pass "secondmate force teardown rejects unsupported child backend before cleanup"
}

test_review_diff_rejects_codex_desktop_meta_before_git() {
  local home err status
  home="$TMP_ROOT/review-codex-home"
  make_home "$home"
  cat > "$home/state/codex.meta" <<'EOF'
backend=codex-desktop
worker_id=desktop-thread-1
kind=ship
worktree=/should/not/read
project=/should/not/read
EOF
  err="$TMP_ROOT/review-codex.err"

  FM_HOME="$home" "$ROOT/bin/fm-review-diff.sh" codex >/dev/null 2>"$err"
  status=$?

  [ "$status" -ne 0 ] || fail "fm-review-diff accepted codex-desktop metadata"
  grep -F 'backend=codex-desktop' "$err" >/dev/null \
    || fail "fm-review-diff did not explain the unsupported backend"
  pass "fm-review-diff rejects codex-desktop metadata before git worktree assumptions"
}

test_promote_rejects_codex_desktop_meta_before_mutation() {
  local home err status before after
  home="$TMP_ROOT/promote-codex-home"
  make_home "$home"
  cat > "$home/state/codex.meta" <<'EOF'
backend=codex-desktop
worker_id=desktop-thread-1
kind=scout
EOF
  before=$(cat "$home/state/codex.meta")
  err="$TMP_ROOT/promote-codex.err"

  FM_HOME="$home" "$ROOT/bin/fm-promote.sh" codex >/dev/null 2>"$err"
  status=$?
  after=$(cat "$home/state/codex.meta")

  [ "$status" -ne 0 ] || fail "fm-promote accepted codex-desktop metadata"
  grep -F 'backend=codex-desktop' "$err" >/dev/null \
    || fail "fm-promote did not explain the unsupported backend"
  [ "$before" = "$after" ] || fail "fm-promote mutated unsupported backend metadata"
  pass "fm-promote rejects codex-desktop metadata before mutation"
}

test_legacy_meta_still_resolves_to_tmux_window
test_window_metadata_is_preferred_for_tmux_targets
test_send_rejects_codex_desktop_meta_before_tmux
test_direct_session_target_still_uses_tmux
test_watch_rejects_codex_desktop_meta_before_tmux
test_teardown_rejects_codex_desktop_meta_before_tmux
test_secondmate_force_teardown_rejects_unsupported_child_backend
test_review_diff_rejects_codex_desktop_meta_before_git
test_promote_rejects_codex_desktop_meta_before_mutation
