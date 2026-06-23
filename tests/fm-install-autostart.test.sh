#!/usr/bin/env bash
# Behavior test for bin/fm-install-autostart.sh unit rendering.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/bin/fm-install-autostart.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-install-autostart-test.XXXXXX")

cleanup() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/bin"

cat > "$TMP/bin/systemctl" <<'SH'
#!/usr/bin/env bash
case "$1" in
  daemon-reload|enable|restart) exit 0 ;;
  is-enabled|is-active) exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$TMP/bin/systemctl"

cat > "$TMP/bin/ps" <<'SH'
#!/usr/bin/env bash
printf 'systemd\n'
SH
chmod +x "$TMP/bin/ps"

cat > "$TMP/bin/id" <<'SH'
#!/usr/bin/env bash
case "${FM_FAKE_ID_MODE:-user}:$1" in
  root:-u) printf '0\n' ;;
  root:-un) printf 'root\n' ;;
  user:-u) printf '1000\n' ;;
  user:-un) printf 'tester\n' ;;
  *) /usr/bin/id "$@" ;;
esac
SH
chmod +x "$TMP/bin/id"

UNIT_DST="$TMP/firstmate.service"
FAKE="$TMP/fake-codex"
cat > "$FAKE" <<'SH'
#!/usr/bin/env bash
sleep 300
SH
chmod +x "$FAKE"

out=$(PATH="$TMP/bin:$PATH" FM_UNIT_DST="$UNIT_DST" FM_FIRSTMATE_HARNESS=codex FM_CODEX_BIN="$FAKE" FM_AUTOSTART_USER=tester FM_AUTOSTART_HOME="$TMP/home/tester" bash "$INSTALLER" install 2>&1) || fail "install failed: $out"

[ -f "$UNIT_DST" ] || fail "unit was not written"
grep -qF "User=tester" "$UNIT_DST" || fail "autostart user was not rendered"
grep -qF "Environment=\"HOME=$TMP/home/tester\"" "$UNIT_DST" || fail "autostart home was not rendered"
grep -qF "WorkingDirectory=\"$ROOT\"" "$UNIT_DST" || fail "WorkingDirectory was not rendered from checkout"
grep -qF "Environment=\"FM_FIRSTMATE_COMMAND=exec $FAKE --dangerously-bypass-approvals-and-sandbox\"" "$UNIT_DST" || fail "firstmate launch command was not rendered from install-time harness"
grep -qF "ExecStart=\"$ROOT/bin/fm-resume.sh\" --watch" "$UNIT_DST" || fail "ExecStart was not rendered from checkout"
! grep -qF '/root/firstmate' "$UNIT_DST" || fail "unit still contains hardcoded /root/firstmate"
! grep -qF '/mnt/c/Users/Owenz' "$UNIT_DST" || fail "unit still contains hardcoded orchestrator config"
! grep -qF '@FM_ROOT@' "$UNIT_DST" || fail "unit still contains template token"
! grep -qF '@FM_FIRSTMATE_COMMAND@' "$UNIT_DST" || fail "unit still contains launch command token"
! grep -qF '@FM_USER@' "$UNIT_DST" || fail "unit still contains user token"
! grep -qF '@FM_HOME@' "$UNIT_DST" || fail "unit still contains home token"

printf '%s\n' "$out" | grep -qF "enabled: no" || fail "missing enabled fallback: $out"
printf '%s\n' "$out" | grep -qF "active: no" || fail "missing active fallback: $out"

BROKEN_UNIT_DST="$TMP/broken-firstmate.service"
broken_out=$(PATH="$TMP/bin:$PATH" FM_UNIT_DST="$BROKEN_UNIT_DST" FM_FIRSTMATE_HARNESS=unknown FM_AUTOSTART_USER=tester FM_AUTOSTART_HOME="$TMP/home/tester" bash "$INSTALLER" install 2>&1)
broken_status=$?
[ "$broken_status" -ne 0 ] || fail "install succeeded with unknown harness"
[ ! -f "$BROKEN_UNIT_DST" ] || fail "unit was written after launch command inference failed"
printf '%s\n' "$broken_out" | grep -qF "cannot infer firstmate launch command" || fail "missing inference failure: $broken_out"

PRIVILEGED_UNIT_DST="$TMP/privileged-firstmate.service"
SUDO_LOG="$TMP/sudo.log"
cat > "$TMP/bin/sudo" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SUDO_LOG"
case "\$1" in
  install)
    cp "\$4" "$PRIVILEGED_UNIT_DST"
    ;;
  systemctl|rm)
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$TMP/bin/sudo"

sudo_out=$(PATH="$TMP/bin:$PATH" FM_FIRSTMATE_HARNESS=codex FM_CODEX_BIN="$FAKE" FM_AUTOSTART_USER=tester FM_AUTOSTART_HOME="$TMP/home/tester" bash "$INSTALLER" install 2>&1) || fail "sudo-backed install failed: $sudo_out"
[ -f "$PRIVILEGED_UNIT_DST" ] || fail "sudo-backed install did not write the unit"
grep -qF "Environment=\"FM_FIRSTMATE_COMMAND=exec $FAKE --dangerously-bypass-approvals-and-sandbox\"" "$PRIVILEGED_UNIT_DST" || fail "sudo-backed install did not render from caller environment"
grep -qF "install -m 0644" "$SUDO_LOG" || fail "install did not use sudo for the system unit"
grep -qF "systemctl daemon-reload" "$SUDO_LOG" || fail "daemon-reload did not use sudo"

SUDO_RENDER_UNIT_DST="$TMP/sudo-render-firstmate.service"
sudo_render_out=$(PATH="$TMP/bin:$PATH" FM_FAKE_ID_MODE=root SUDO_USER=tester FM_UNIT_DST="$SUDO_RENDER_UNIT_DST" FM_FIRSTMATE_HARNESS=codex FM_CODEX_BIN="$FAKE" FM_AUTOSTART_HOME="$TMP/home/tester" bash "$INSTALLER" install 2>&1)
sudo_render_status=$?
[ "$sudo_render_status" -ne 0 ] || fail "sudo-invoked install without explicit command succeeded"
[ ! -f "$SUDO_RENDER_UNIT_DST" ] || fail "sudo-invoked install wrote a unit before refusal"
printf '%s\n' "$sudo_render_out" | grep -qF "run without sudo" || fail "missing sudo-render refusal: $sudo_render_out"

pass "fm-install-autostart renders firstmate.service from the active checkout"
