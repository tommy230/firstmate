#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh worktree detection.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-spawn-worktree.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

make_fake_tools() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "${1:-}" in
  has-session|new-session|new-window|send-keys)
    exit 0
    ;;
  list-windows)
    exit 0
    ;;
  display-message)
    printf '%s\n' "$FM_FAKE_PANE_PATH"
    exit 0
    ;;
esac
exit 1
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
}

make_project_with_global_worktree() {
  local project=$1 worktree=$2
  mkdir -p "$project"
  git -C "$project" init -q
  git -C "$project" checkout -q -b main
  git -C "$project" -c user.name='Firstmate Test' -c user.email='test@example.invalid' commit --allow-empty -q -m init
  git -C "$project" worktree add -q -b fm/task-global "$worktree" main
}

test_spawn_accepts_registered_worktree_outside_project_tree() {
  local home project worktree fakebin log meta out
  home="$TMP_ROOT/home"
  project="$home/projects/alpha"
  worktree="$TMP_ROOT/global treehouse/task-global"
  fakebin="$TMP_ROOT/fakebin"
  log="$TMP_ROOT/tmux.log"
  mkdir -p "$home/data/task-global" "$home/state" "$(dirname "$worktree")"
  printf 'brief\n' > "$home/data/task-global/brief.md"
  make_project_with_global_worktree "$project" "$worktree"
  make_fake_tools "$fakebin"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SPAWN_NO_GUARD=1 FM_FAKE_TMUX_LOG="$log" FM_FAKE_PANE_PATH="$worktree" \
    "$SPAWN" task-global projects/alpha codex 2>&1) || fail "spawn rejected registered global worktree: $out"

  meta="$home/state/task-global.meta"
  grep -Fx "worktree=$worktree" "$meta" >/dev/null || fail "spawn did not record global worktree path"
  printf '%s\n' "$out" | grep -F "worktree=$worktree" >/dev/null || fail "spawn output omitted global worktree"
  pass "spawn accepts a registered worktree outside the project tree"
}

test_spawn_accepts_registered_worktree_outside_project_tree
