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
  *) exit 0 ;;
esac
SH
chmod +x "$TMP/bin/systemctl"

cat > "$TMP/bin/ps" <<'SH'
#!/usr/bin/env bash
printf 'systemd\n'
SH
chmod +x "$TMP/bin/ps"

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

pass "fm-install-autostart renders firstmate.service from the active checkout"
