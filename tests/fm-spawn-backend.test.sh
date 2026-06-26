#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh worker backend metadata and tmux-treehouse path.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT/bin/fm-spawn.sh"
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

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-spawn-backend.XXXXXX")

make_fake_tmux() {
  local dir=$1 fakebin log
  fakebin="$dir/fakebin"
  log="$dir/tmux.log"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  has-session|new-session|new-window|send-keys)
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    exit 0
    ;;
  list-windows)
    if [ -n "${FM_FAKE_TMUX_WINDOW:-}" ]; then
      printf '%s\n' "$FM_FAKE_TMUX_WINDOW"
    fi
    exit 0
    ;;
  display-message)
    case " $* " in
      *'#{pane_current_path}'*) printf '%s\n' "$FM_FAKE_TMUX_PANE_PATH" ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  : > "$log"
  printf '%s\n' "$fakebin"
}

make_home_with_project() {
  local home=$1 project=$2 mode=${3:-direct-PR} yolo=${4-+yolo}
  mkdir -p "$home/data" "$home/projects/$project"
  cat > "$home/data/projects.md" <<EOF
# Projects

- $project [$mode $yolo] - backend spawn test project (added 2026-06-24)
EOF
}

test_ship_spawn_records_backend_metadata() {
  local home project wt fakebin log out meta project_abs wt_abs
  home="$TMP_ROOT/ship-home"
  project=alpha
  wt="$TMP_ROOT/ship-worktree"
  mkdir -p "$wt"
  make_home_with_project "$home" "$project"
  mkdir -p "$home/data/backend-ship"
  printf 'ship brief\n' > "$home/data/backend-ship/brief.md"
  project_abs=$(cd "$home/projects/$project" && pwd)
  wt_abs=$(cd "$wt" && pwd)
  fakebin=$(make_fake_tmux "$TMP_ROOT/ship-fake")
  log="$TMP_ROOT/ship-fake/tmux.log"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_PANE_PATH="$wt_abs" \
    "$SPAWN" backend-ship "projects/$project" codex 2>&1) \
    || fail "ship spawn failed: $out"

  meta="$home/state/backend-ship.meta"
  grep -Fx 'backend=tmux-treehouse' "$meta" >/dev/null || fail "meta did not record backend"
  grep -Fx 'worker_id=firstmate:fm-backend-ship' "$meta" >/dev/null || fail "meta did not record worker id"
  grep -Fx "worker_project_path=$project_abs" "$meta" >/dev/null || fail "meta did not record project path"
  grep -Fx 'environment=treehouse' "$meta" >/dev/null || fail "meta did not record treehouse environment"
  grep -Fx 'window=firstmate:fm-backend-ship' "$meta" >/dev/null || fail "meta did not record tmux window"
  grep -Fx "worktree=$wt_abs" "$meta" >/dev/null || fail "meta did not record worktree"
  grep -Fx "project=$project_abs" "$meta" >/dev/null || fail "meta did not record project"
  grep -Fx 'harness=codex' "$meta" >/dev/null || fail "meta did not record harness"
  grep -Fx 'kind=ship' "$meta" >/dev/null || fail "meta did not record ship kind"
  grep -Fx 'mode=direct-PR' "$meta" >/dev/null || fail "meta did not record project mode"
  grep -Fx 'yolo=on' "$meta" >/dev/null || fail "meta did not record yolo"
  printf '%s\n' "$out" | grep -F "spawned backend-ship backend=tmux-treehouse harness=codex kind=ship mode=direct-PR yolo=on window=firstmate:fm-backend-ship worktree=$wt_abs" >/dev/null \
    || fail "spawn output did not preserve backend summary"
  grep -F "new-window -d -t firstmate -n fm-backend-ship -c $project_abs" "$log" >/dev/null \
    || fail "spawn did not create tmux window in project"
  grep -F 'send-keys -t firstmate:fm-backend-ship treehouse get Enter' "$log" >/dev/null \
    || fail "spawn did not keep treehouse get launch path"
  grep -F 'codex --dangerously-bypass-approvals-and-sandbox' "$log" >/dev/null \
    || fail "spawn did not send codex launch command"
  grep -F ' -c "notify=[' "$log" >/dev/null \
    || fail "spawn did not keep codex turn-end notify command"
  pass "ship spawn records explicit tmux-treehouse backend metadata"
}

test_scout_spawn_uses_same_backend_boundary() {
  local home project wt fakebin log out meta wt_abs
  home="$TMP_ROOT/scout-home"
  project=bravo
  wt="$TMP_ROOT/scout-worktree"
  mkdir -p "$wt"
  make_home_with_project "$home" "$project" local-only ''
  mkdir -p "$home/data/backend-scout"
  printf 'scout brief\n' > "$home/data/backend-scout/brief.md"
  wt_abs=$(cd "$wt" && pwd)
  fakebin=$(make_fake_tmux "$TMP_ROOT/scout-fake")
  log="$TMP_ROOT/scout-fake/tmux.log"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_PANE_PATH="$wt_abs" \
    "$SPAWN" backend-scout "projects/$project" codex --scout 2>&1) \
    || fail "scout spawn failed: $out"

  meta="$home/state/backend-scout.meta"
  grep -Fx 'backend=tmux-treehouse' "$meta" >/dev/null || fail "scout meta did not record backend"
  grep -Fx 'environment=treehouse' "$meta" >/dev/null || fail "scout meta did not record environment"
  grep -Fx 'kind=scout' "$meta" >/dev/null || fail "scout meta did not record scout kind"
  grep -Fx 'mode=local-only' "$meta" >/dev/null || fail "scout meta did not keep project mode"
  grep -Fx 'yolo=off' "$meta" >/dev/null || fail "scout meta did not record yolo off"
  printf '%s\n' "$out" | grep -F "spawned backend-scout backend=tmux-treehouse harness=codex kind=scout mode=local-only yolo=off window=firstmate:fm-backend-scout worktree=$wt_abs" >/dev/null \
    || fail "scout output did not preserve backend summary"
  grep -F 'send-keys -t firstmate:fm-backend-scout treehouse get Enter' "$log" >/dev/null \
    || fail "scout spawn did not keep treehouse get launch path"
  pass "scout spawn uses the same explicit backend metadata"
}

test_codex_desktop_backend_fails_closed_until_real_api_exists() {
  local home project wt fakebin log out status
  home="$TMP_ROOT/unsupported-home"
  project=charlie
  wt="$TMP_ROOT/unsupported-worktree"
  mkdir -p "$wt"
  make_home_with_project "$home" "$project"
  mkdir -p "$home/data/backend-unsupported"
  printf 'brief\n' > "$home/data/backend-unsupported/brief.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/unsupported-fake")
  log="$TMP_ROOT/unsupported-fake/tmux.log"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
    FM_WORKER_BACKEND=codex-desktop FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_PANE_PATH="$wt" \
    "$SPAWN" backend-unsupported "projects/$project" codex 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "codex-desktop backend should fail until implemented"
  printf '%s\n' "$out" | grep -F 'worker backend codex-desktop is not implemented' >/dev/null \
    || fail "codex-desktop refusal did not explain missing real API"
  [ ! -s "$log" ] || fail "unsupported backend reached tmux side effects"
  [ ! -e "$home/state/backend-unsupported.meta" ] || fail "unsupported backend wrote metadata"
  pass "codex-desktop backend fails closed before tmux side effects"
}

test_unknown_backend_fails_closed_before_side_effects() {
  local home project fakebin log out status
  home="$TMP_ROOT/unknown-home"
  project="delta"
  make_home_with_project "$home" "$project"
  mkdir -p "$home/data/backend-unknown"
  printf 'brief\n' > "$home/data/backend-unknown/brief.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/unknown-fake")
  log="$TMP_ROOT/unknown-fake/tmux.log"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
    FM_WORKER_BACKEND=bogus FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_PANE_PATH="$home/projects/$project" \
    "$SPAWN" backend-unknown "projects/$project" codex 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unknown backend should fail"
  printf '%s\n' "$out" | grep -F "unsupported worker backend 'bogus'" >/dev/null \
    || fail "unknown backend refusal did not name backend"
  [ ! -s "$log" ] || fail "unknown backend reached tmux side effects"
  [ ! -e "$home/state/backend-unknown.meta" ] || fail "unknown backend wrote metadata"
  pass "unknown backend fails closed before tmux side effects"
}

test_ship_spawn_records_backend_metadata
test_scout_spawn_uses_same_backend_boundary
test_codex_desktop_backend_fails_closed_until_real_api_exists
test_unknown_backend_fails_closed_before_side_effects
