#!/usr/bin/env bash
# Install (or remove) the systemd unit that makes firstmate survive a WSL VM
# teardown - the failure that took the fleet out overnight (AGENTS.md section 5).
#
# systemd runs as PID 1 in this distro ([boot] systemd=true in /etc/wsl.conf),
# so a system unit started at multi-user.target is the native, reboot-proof way
# to auto-resurrect firstmate. The unit runs bin/fm-resume.sh as a watchdog.
#
# Usage:
#   fm-install-autostart.sh            install, enable, and start the unit
#   fm-install-autostart.sh status     show unit + session state
#   fm-install-autostart.sh uninstall  stop, disable, and remove the unit
#
# Reversible: `uninstall` leaves no trace and never touches a running firstmate
# session (KillMode=process in the unit), so removing autostart cannot discard work.
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_SRC="$FM_ROOT/systemd/firstmate.service"
UNIT_NAME="firstmate.service"
UNIT_DST="${FM_UNIT_DST:-/etc/systemd/system/$UNIT_NAME}"
SYSTEM_UNIT_DST="/etc/systemd/system/$UNIT_NAME"

shell_quote() {
  local out
  printf -v out '%q' "$1"
  printf '%s' "$out"
}

systemd_quote() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s' "$value"
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
  if [ -n "${FM_FIRSTMATE_COMMAND:-}" ]; then
    printf '%s\n' "$FM_FIRSTMATE_COMMAND"
    return 0
  fi
  harness="${FM_FIRSTMATE_HARNESS:-}"
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

autostart_user() {
  if [ -n "${FM_AUTOSTART_USER:-}" ]; then
    printf '%s\n' "$FM_AUTOSTART_USER"
  elif [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    printf '%s\n' "$SUDO_USER"
  else
    id -un
  fi
}

autostart_home() {
  local user=$1 home
  if [ -n "${FM_AUTOSTART_HOME:-}" ]; then
    printf '%s\n' "$FM_AUTOSTART_HOME"
    return 0
  fi
  home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)
  if [ -n "$home" ]; then
    printf '%s\n' "$home"
    return 0
  fi
  if [ "$user" = "$(id -un)" ]; then
    printf '%s\n' "$HOME"
    return 0
  fi
  echo "error: cannot determine home for autostart user '$user'; set FM_AUTOSTART_HOME" >&2
  return 1
}

render_unit() {
  local root raw_command command raw_user user raw_home home line
  root=$(systemd_quote "$FM_ROOT")
  raw_command=$(firstmate_command) || return 1
  command=$(systemd_quote "$raw_command")
  raw_user=$(autostart_user)
  user=$(systemd_quote "$raw_user")
  raw_home=$(autostart_home "$raw_user") || return 1
  home=$(systemd_quote "$raw_home")
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line//@FM_ROOT@/$root}
    line=${line//@FM_FIRSTMATE_COMMAND@/$command}
    line=${line//@FM_USER@/$user}
    printf '%s\n' "${line//@FM_HOME@/$home}"
  done < "$UNIT_SRC"
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "error: systemctl not found; this distro is not running systemd" >&2
    exit 1
  fi
  if [ "$(ps -p 1 -o comm= 2>/dev/null)" != systemd ]; then
    echo "error: PID 1 is not systemd; enable '[boot] systemd=true' in /etc/wsl.conf, then 'wsl --shutdown'" >&2
    exit 1
  fi
}

requires_privilege() {
  [ "$UNIT_DST" = "$SYSTEM_UNIT_DST" ] || return 1
  [ "$(id -u)" -ne 0 ]
}

run_privileged() {
  if requires_privilege; then
    sudo "$@"
  else
    "$@"
  fi
}

refuse_ambiguous_sudo_render() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && [ -z "${FM_FIRSTMATE_COMMAND:-}" ]; then
    echo "error: run without sudo so the firstmate launch command is captured from your user session" >&2
    echo "       or set FM_FIRSTMATE_COMMAND explicitly when invoking through sudo" >&2
    exit 1
  fi
}

cmd_install() {
  local rendered
  require_systemd
  [ -f "$UNIT_SRC" ] || { echo "error: unit not found at $UNIT_SRC" >&2; exit 1; }
  refuse_ambiguous_sudo_render
  rendered=$(mktemp "${TMPDIR:-/tmp}/firstmate.service.XXXXXX")
  trap 'rm -f "$rendered"' EXIT
  render_unit > "$rendered"
  # Install a copy (not a symlink): systemd does not follow symlinks under
  # /mnt/c reliably, and the repo path is not guaranteed mounted at early boot.
  run_privileged install -m 0644 "$rendered" "$UNIT_DST"
  rm -f "$rendered"
  trap - EXIT
  run_privileged systemctl daemon-reload
  run_privileged systemctl enable "$UNIT_NAME"
  run_privileged systemctl restart "$UNIT_NAME"
  echo "installed and enabled $UNIT_NAME"
  echo "firstmate will now auto-resurrect on every boot and self-heal if it dies."
  cmd_status
}

cmd_uninstall() {
  require_systemd
  run_privileged systemctl disable "$UNIT_NAME" 2>/dev/null || true
  run_privileged systemctl stop "$UNIT_NAME" 2>/dev/null || true
  run_privileged rm -f "$UNIT_DST"
  run_privileged systemctl daemon-reload
  echo "removed $UNIT_NAME (any running firstmate session was left untouched)"
}

cmd_status() {
  require_systemd
  echo "--- unit ---"
  if enabled=$(systemctl is-enabled "$UNIT_NAME" 2>/dev/null); then
    printf 'enabled: %s\n' "$enabled"
  else
    echo "enabled: no"
  fi
  if active=$(systemctl is-active "$UNIT_NAME" 2>/dev/null); then
    printf 'active: %s\n' "$active"
  else
    echo "active: no"
  fi
  echo "--- session ---"
  if tmux has-session -t "${FM_SESSION:-firstmate}" 2>/dev/null; then
    echo "firstmate tmux session: LIVE (attach with: tmux attach -t ${FM_SESSION:-firstmate})"
  else
    echo "firstmate tmux session: not present"
  fi
}

case "${1:-install}" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status ;;
  *) echo "usage: $(basename "$0") [install|status|uninstall]" >&2; exit 2 ;;
esac
