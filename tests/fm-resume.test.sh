#!/usr/bin/env bash
# Behavior tests for bin/fm-resume.sh - the crash/reboot resurrection script.
# Runs against a private tmux server (-L socket) so it never touches the live
# firstmate session, and sets base-index 1 on that server to guard the bug where
# send-keys targeted a hardcoded window ":0" that does not exist under base-index 1.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESUME="$ROOT/bin/fm-resume.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if ! command -v tmux >/dev/null 2>&1; then
  printf 'ok - SKIP fm-resume (tmux not installed)\n'
  exit 0
fi

REAL_TMUX=$(command -v tmux)
SOCK="fmresume$$"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-resume-test.XXXXXX")

cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}
trap cleanup EXIT

# Private server with base-index 1; a dummy session keeps the server alive and
# proves new sessions inherit the non-zero base index.
"$REAL_TMUX" -L "$SOCK" new-session -d -s seed -x 80 -y 24
"$REAL_TMUX" -L "$SOCK" set -g base-index 1

# Wrapper so fm-resume's bare `tmux` calls hit the private server.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
chmod +x "$TMP/bin/tmux"

# Fake firstmate binary: records its launch context, then idles.
FAKE="$TMP/fake-claude"
cat > "$FAKE" <<EOF
#!/usr/bin/env bash
printf 'cwd=%s cfg=%s sandbox=%s\n' "\$PWD" "\${CLAUDE_CONFIG_DIR:-}" "\${IS_SANDBOX:-}" > "$TMP/launch.txt"
sleep 300
EOF
chmod +x "$FAKE"

run_resume() {
  PATH="$TMP/bin:$PATH" FM_SESSION=fmtest FM_FIRSTMATE_HARNESS=claude FM_CLAUDE_BIN="$FAKE" FM_CONFIG_DIR=/cfg/orch "$RESUME"
}

# 1) create path: session made, firstmate launched with the right context.
out=$(run_resume) || fail "resume create returned nonzero"
printf '%s\n' "$out" | grep -q "created session 'fmtest'" || fail "create not reported: $out"
for _ in $(seq 1 40); do [ -f "$TMP/launch.txt" ] && break; sleep 0.25; done
[ -f "$TMP/launch.txt" ] || fail "firstmate never launched (base-index regression?)"
grep -qF "cwd=$ROOT " "$TMP/launch.txt" || fail "wrong cwd: $(cat "$TMP/launch.txt")"
grep -qF "cfg=/cfg/orch " "$TMP/launch.txt" || fail "config dir not applied: $(cat "$TMP/launch.txt")"
grep -qF "sandbox=1" "$TMP/launch.txt" || fail "IS_SANDBOX not set: $(cat "$TMP/launch.txt")"
pass "fm-resume creates the session and launches firstmate with the right context"

# 2) idempotent: a second run no-ops and never makes a duplicate session.
out2=$(run_resume) || fail "resume no-op returned nonzero"
printf '%s\n' "$out2" | grep -q "already live" || fail "second run should no-op: $out2"
count=$("$REAL_TMUX" -L "$SOCK" list-sessions 2>/dev/null | grep -c '^fmtest:')
[ "$count" -eq 1 ] || fail "expected exactly one fmtest session, got $count"
pass "fm-resume is idempotent (no duplicate session)"

# 3) launch-command inference failure under --watch must not wedge an empty session.
FM_SESSION=fmfail FM_FIRSTMATE_HARNESS=unknown FM_RESUME_INTERVAL=1 PATH="$TMP/bin:$PATH" "$RESUME" --watch > "$TMP/watch-fail.out" 2>&1 &
watch_pid=$!
sleep 0.5
kill "$watch_pid" 2>/dev/null || true
wait "$watch_pid" 2>/dev/null || true
if "$REAL_TMUX" -L "$SOCK" has-session -t fmfail 2>/dev/null; then
  fail "watch mode created an empty session after launch command failure"
fi
grep -qF "cannot infer firstmate launch command" "$TMP/watch-fail.out" || fail "watch mode did not report launch command failure"
pass "fm-resume --watch does not create an empty session after launch inference failure"

# 4) a supported harness with no binary must fail before creating a session.
FM_SESSION=fmmissing FM_FIRSTMATE_HARNESS=codex FM_RESUME_INTERVAL=1 PATH="$TMP/bin:/usr/bin:/bin" "$RESUME" --watch > "$TMP/watch-missing-bin.out" 2>&1 &
missing_pid=$!
sleep 0.5
kill "$missing_pid" 2>/dev/null || true
wait "$missing_pid" 2>/dev/null || true
if "$REAL_TMUX" -L "$SOCK" has-session -t fmmissing 2>/dev/null; then
  fail "watch mode created an empty session after harness binary lookup failed"
fi
! grep -qF "exec  --dangerously-bypass-approvals-and-sandbox" "$TMP/watch-missing-bin.out" || fail "missing binary produced an empty launch command"
pass "fm-resume --watch does not create an empty session after harness binary lookup failure"
