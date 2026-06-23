#!/usr/bin/env bash
# Idempotently ensure the persistent firstmate tmux session exists.
#
# This is the recovery half of crash resilience (AGENTS.md section 5): a WSL VM
# teardown (host sleep, idle timeout, or a Windows Update reboot) kills the tmux
# server and every process in it, including firstmate and any crewmates. systemd
# survives the reboot but nothing relaunched firstmate - so it stayed dead until
# the captain reconnected. This script, run at boot and on a self-heal timer by
# firstmate.service (see systemd/), brings the session back automatically. The
# captain then attaches to a live, state-intact firstmate instead of a cold start.
#
# It is deliberately idempotent and safe to run repeatedly: if the session is
# already alive it is a no-op. It does NOT relaunch crewmate workers - their
# autonomous processes died with the VM and re-spawning them is firstmate's job
# via its recovery protocol once the captain is back. Worker state on disk
# (data/, state/, backlog) is untouched and survives regardless.
#
# Usage:
#   fm-resume.sh            ensure the session once, then exit
#   fm-resume.sh --watch    ensure forever, re-checking every FM_RESUME_INTERVAL
#                           seconds (the long-running ExecStart for the service)
#
# Useful overrides:
#   FM_SESSION names the persistent tmux session (default: firstmate).
#   FM_FIRSTMATE_HARNESS / FM_FIRSTMATE_COMMAND choose the launch command.
#   FM_CLAUDE_BIN, FM_CODEX_BIN, FM_OPENCODE_BIN, or FM_PI_BIN pin a binary.
#   FM_CONFIG_DIR sets CLAUDE_CONFIG_DIR for Claude launches.
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SESSION="${FM_SESSION:-firstmate}"
FM_FIRSTMATE_HARNESS="${FM_FIRSTMATE_HARNESS:-}"
FM_FIRSTMATE_COMMAND="${FM_FIRSTMATE_COMMAND:-}"
FM_RESUME_INTERVAL="${FM_RESUME_INTERVAL:-60}"

shell_quote() {
  local out
  printf -v out '%q' "$1"
  printf '%s' "$out"
}

firstmate_bin() {
  local harness=$1 var value
  var="FM_$(printf '%s' "$harness" | tr '[:lower:]' '[:upper:]')_BIN"
  eval "value=\${$var:-}"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
    return 0
  fi
  command -v "$harness"
}

firstmate_command() {
  local harness bin config
  if [ -n "$FM_FIRSTMATE_COMMAND" ]; then
    printf '%s\n' "$FM_FIRSTMATE_COMMAND"
    return 0
  fi
  harness=$FM_FIRSTMATE_HARNESS
  if [ -z "$harness" ]; then
    harness=$("$FM_ROOT/bin/fm-harness.sh" 2>/dev/null || echo unknown)
  fi
  case "$harness" in
    claude)
      bin=$(firstmate_bin claude) || return 1
      config="${FM_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-}}"
      if [ -n "$config" ]; then
        printf 'CLAUDE_CONFIG_DIR=%s IS_SANDBOX=1 exec %s --dangerously-skip-permissions\n' "$(shell_quote "$config")" "$(shell_quote "$bin")"
      else
        printf 'IS_SANDBOX=1 exec %s --dangerously-skip-permissions\n' "$(shell_quote "$bin")"
      fi
      ;;
    codex)
      bin=$(firstmate_bin codex) || return 1
      printf 'exec %s --dangerously-bypass-approvals-and-sandbox\n' "$(shell_quote "$bin")"
      ;;
    opencode)
      bin=$(firstmate_bin opencode) || return 1
      printf 'OPENCODE_CONFIG_CONTENT=%s exec %s\n' "$(shell_quote '{"permission":{"*":"allow"}}')" "$(shell_quote "$bin")"
      ;;
    pi)
      bin=$(firstmate_bin pi) || return 1
      printf 'exec %s\n' "$(shell_quote "$bin")"
      ;;
    *)
      echo "error: cannot infer firstmate launch command for harness '$harness'; set FM_FIRSTMATE_COMMAND" >&2
      return 1
      ;;
  esac
}

ensure_session() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    return 0
  fi

  local launch command
  command=$(firstmate_command) || return 1
  printf -v launch \
    'cd %q && %s' \
    "$FM_ROOT" "$command"

  # Target the session (active window) rather than a hardcoded ":0": tmux configs
  # commonly set base-index 1, so the first window is not always index 0.
  tmux new-session -d -s "$SESSION" -c "$FM_ROOT"
  tmux send-keys -t "$SESSION" "$launch" Enter
  echo "fm-resume: created session '$SESSION' running firstmate"
  return 0
}

if [ "${1:-}" = "--watch" ]; then
  while :; do
    ensure_session || true
    sleep "$FM_RESUME_INTERVAL"
  done
else
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "fm-resume: session '$SESSION' already live"
  else
    ensure_session
  fi
fi
