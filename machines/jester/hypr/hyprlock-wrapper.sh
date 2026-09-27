#!/run/current-system/sw/bin/bash
# Single instance. flock is atomic; the old pidof check let two lock_cmd calls
# fired at the same moment both start hyprlock (2026-09-24). hyprlock inherits
# fd 9, so the lock is held for its whole life.
exec 9>"$XDG_RUNTIME_DIR/hyprlock.lock"
/run/current-system/sw/bin/flock -n 9 || exit 0

# Per-session log capture. hyprlock's stdout is otherwise an inherited socket
# (journalctl shows nothing useful), and per-session logs were what let us
# diagnose the post-resume fingerprint/auth lockout (2026-09-27): hyprlock
# arms the sensor fine at lock time, but never re-issues VerifyStart after
# "fprint: PrepareForSleep (start: false)", and password auth breaks across
# the same suspend/resume boundary too. No stdbuf needed here: hyprutils
# 0.14.0 CLoggerImpl::log() does an unconditional fflush(stdout) per line, so
# plain redirection already gets every line as it's written.
log_dir="$XDG_RUNTIME_DIR/hyprlock-logs"
/run/current-system/sw/bin/mkdir -p "$log_dir"
log_file="$log_dir/$(/run/current-system/sw/bin/date +%Y%m%d-%H%M%S)-$$.log"
# Rotate: keep only the 50 most recent logs.
/run/current-system/sw/bin/ls -1t "$log_dir" 2>/dev/null | /run/current-system/sw/bin/tail -n +51 | \
    while IFS= read -r old; do /run/current-system/sw/bin/rm -f "$log_dir/$old"; done

# This trap does NOT run when hyprlock exits, crashes, or is killed. exec
# below replaces this shell's process image, and exec discards any pending
# trap along with the shell itself. The trap can only fire if exec fails to
# start hyprlock in the first place (binary missing or not executable), in
# which case this shell keeps running and the EXIT trap covers that one case:
# clearing logind LockedHint so apps reading session lock state
# (fafnir-approve) don't block on a stale flag.
# No fprintd restart: fprintd drops a claim when its D-Bus owner exits, and
# hyprlock never reconnects to a restarted fprintd.
trap '/run/current-system/sw/bin/loginctl unlock-session' EXIT
exec /run/current-system/sw/bin/hyprlock "$@" >>"$log_file" 2>&1
