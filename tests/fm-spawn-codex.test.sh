#!/usr/bin/env bash
# Behavior tests for the Codex fm-spawn launch template.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-spawn-codex.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

make_fake_tmux() {
  local dir=$1 fakebin
  fakebin="$dir/fakebin"
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
    exit 0
    ;;
  display-message)
    printf '%s\n' "$FM_FAKE_WORKTREE"
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

make_spawn_home() {
  local home=$1 worktree=$2
  mkdir -p "$home/data/codex-launch-z1" "$home/data/codex-scout-z2" "$home/projects/alpha" "$home/state" "$worktree"
  printf 'ship brief\n' > "$home/data/codex-launch-z1/brief.md"
  printf 'scout brief\n' > "$home/data/codex-scout-z2/brief.md"
  printf '%s\n' '- alpha [direct-PR] - alpha test project (added 2026-06-23)' > "$home/data/projects.md"
}

assert_codex_launch_has_mcp_disables_and_notify() {
  local log=$1 task=$2 turnend=$3
  grep -F 'codex --dangerously-bypass-approvals-and-sandbox' "$log" >/dev/null \
    || fail "$task did not launch codex"
  grep -F -- '-c mcp_servers.agent-native-web-production-e480f.enabled=false' "$log" >/dev/null \
    || fail "$task did not disable agent-native-web-production MCP"
  grep -F -- '-c mcp_servers.agent-native-dispatch.enabled=false' "$log" >/dev/null \
    || fail "$task did not disable agent-native-dispatch MCP"
  grep -F -- "-c \"notify=[\\\"bash\\\",\\\"-c\\\",\\\"touch '$turnend'\\\"]\"" "$log" >/dev/null \
    || fail "$task did not preserve codex notify turn-end config"
}

test_codex_ship_launch_disables_noisy_mcp_servers() {
  local home worktree fakebin log
  home="$TMP_ROOT/ship-home"
  worktree="$TMP_ROOT/ship-worktree"
  make_spawn_home "$home" "$worktree"
  fakebin=$(make_fake_tmux "$TMP_ROOT/ship-fake")
  log="$TMP_ROOT/ship-fake/tmux.log"
  : > "$log"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WORKTREE="$worktree" FM_FAKE_TMUX_LOG="$log" \
    "$SPAWN" codex-launch-z1 projects/alpha codex >/dev/null \
    || fail "codex ship spawn failed"

  assert_codex_launch_has_mcp_disables_and_notify "$log" "ship" "$home/state/codex-launch-z1.turn-ended"
  pass "codex ship launch disables noisy MCP servers and keeps notify"
}

test_codex_scout_launch_disables_noisy_mcp_servers() {
  local home worktree fakebin log
  home="$TMP_ROOT/scout-home"
  worktree="$TMP_ROOT/scout-worktree"
  make_spawn_home "$home" "$worktree"
  fakebin=$(make_fake_tmux "$TMP_ROOT/scout-fake")
  log="$TMP_ROOT/scout-fake/tmux.log"
  : > "$log"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WORKTREE="$worktree" FM_FAKE_TMUX_LOG="$log" \
    "$SPAWN" codex-scout-z2 projects/alpha codex --scout >/dev/null \
    || fail "codex scout spawn failed"

  assert_codex_launch_has_mcp_disables_and_notify "$log" "scout" "$home/state/codex-scout-z2.turn-ended"
  pass "codex scout launch disables noisy MCP servers and keeps notify"
}

test_codex_ship_launch_disables_noisy_mcp_servers
test_codex_scout_launch_disables_noisy_mcp_servers
