#!/usr/bin/env bash
# Shared worker metadata helpers.

fm_worker_meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_worker_backend_for_meta() {  # <meta>
  local backend
  backend=$(fm_worker_meta_value "$1" backend)
  [ -n "$backend" ] || backend=tmux-treehouse
  printf '%s\n' "$backend"
}

fm_worker_require_tmux_treehouse() {  # <id> <meta> <command-name>
  local id=$1 meta=$2 command_name=$3 backend
  backend=$(fm_worker_backend_for_meta "$meta")
  case "$backend" in
    tmux-treehouse) return 0 ;;
    codex-desktop)
      echo "error: task $id uses backend=codex-desktop; $command_name currently supports only tmux-treehouse workers" >&2
      return 1
      ;;
    *)
      echo "error: task $id uses unsupported worker backend '$backend'; $command_name currently supports only tmux-treehouse workers" >&2
      return 1
      ;;
  esac
}

fm_worker_resolve_tmux_target() {  # <arg> <state-dir> <command-name>
  local target=$1 state=$2 command_name=$3 meta id window
  case "$target" in
    *:*) printf '%s\n' "$target" ;;
    fm-*)
      id=${target#fm-}
      meta="$state/$id.meta"
      if [ ! -f "$meta" ]; then
        echo "error: no metadata for $target in $state; pass session:window to target a window outside this firstmate home" >&2
        return 1
      fi
      fm_worker_require_tmux_treehouse "$id" "$meta" "$command_name" || return 1
      window=$(fm_worker_meta_value "$meta" window)
      [ -n "$window" ] || window=$(fm_worker_meta_value "$meta" worker_id)
      [ -n "$window" ] || { echo "error: no window recorded in $meta" >&2; return 1; }
      printf '%s\n' "$window"
      ;;
    *)
      tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$target\$" \
        || { echo "error: no window named $target" >&2; return 1; }
      ;;
  esac
}
