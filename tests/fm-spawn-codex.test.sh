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
  local home=$1 worktree=$2 project=$3
  mkdir -p "$home/data/codex-launch-z1" "$home/projects/$project" "$home/state" "$worktree"
  printf 'ship brief\n' > "$home/data/codex-launch-z1/brief.md"
  printf -- '- %s [direct-PR] - test project (added 2026-06-24)\n' "$project" > "$home/data/projects.md"
}

run_codex_spawn() {
  local project=$1 home worktree fakebin log
  home="$TMP_ROOT/$project-home"
  worktree="$TMP_ROOT/$project-worktree"
  make_spawn_home "$home" "$worktree" "$project"
  fakebin=$(make_fake_tmux "$TMP_ROOT/$project-fake")
  log="$TMP_ROOT/$project-fake/tmux.log"
  : > "$log"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WORKTREE="$worktree" FM_FAKE_TMUX_LOG="$log" \
    "$SPAWN" codex-launch-z1 "projects/$project" codex >/dev/null \
    || fail "codex spawn failed for $project"

  printf '%s\n' "$log"
}

assert_codex_launch_has_notify() {
  local log=$1 turnend=$2
  grep -F 'codex --dangerously-bypass-approvals-and-sandbox' "$log" >/dev/null \
    || fail "spawn did not launch codex"
  grep -F -- "-c \"notify=[\\\"bash\\\",\\\"-c\\\",\\\"touch '$turnend'\\\"]\"" "$log" >/dev/null \
    || fail "spawn did not preserve codex notify turn-end config"
}

assert_codex_launch_has_agent_native_mcp_disables() {
  local log=$1
  grep -F -- '-c mcp_servers.agent-native-web-production-e480f.enabled=false' "$log" >/dev/null \
    || fail "spawn did not disable agent-native-web-production MCP"
  grep -F -- '-c mcp_servers.agent-native-dispatch.enabled=false' "$log" >/dev/null \
    || fail "spawn did not disable agent-native-dispatch MCP"
}

assert_codex_launch_lacks_agent_native_mcp_disables() {
  local log=$1
  if grep -F -- '-c mcp_servers.agent-native-web-production-e480f.enabled=false' "$log" >/dev/null; then
    fail "agent-native spawn disabled agent-native-web-production MCP"
  fi
  if grep -F -- '-c mcp_servers.agent-native-dispatch.enabled=false' "$log" >/dev/null; then
    fail "agent-native spawn disabled agent-native-dispatch MCP"
  fi
}

test_codex_non_agent_native_launch_disables_agent_native_mcp_servers() {
  local project home log
  project=alpha
  home="$TMP_ROOT/$project-home"
  log=$(run_codex_spawn "$project")

  assert_codex_launch_has_notify "$log" "$home/state/codex-launch-z1.turn-ended"
  assert_codex_launch_has_agent_native_mcp_disables "$log"
  pass "codex launch disables agent-native MCP servers outside agent-native repos"
}

test_codex_agent_native_launch_keeps_agent_native_mcp_servers_enabled() {
  local project home log
  project=agent-native-main
  home="$TMP_ROOT/$project-home"
  log=$(run_codex_spawn "$project")

  assert_codex_launch_has_notify "$log" "$home/state/codex-launch-z1.turn-ended"
  assert_codex_launch_lacks_agent_native_mcp_disables "$log"
  pass "codex launch keeps agent-native MCP servers available in agent-native repos"
}

test_codex_non_agent_native_launch_disables_agent_native_mcp_servers
test_codex_agent_native_launch_keeps_agent_native_mcp_servers_enabled
