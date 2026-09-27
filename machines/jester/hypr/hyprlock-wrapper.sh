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

# Arm-check, wired to run after every lock regardless of how it started.
# hyprlock 0.9.6 arms the fingerprint reader once, inside the async D-Bus
# reply to login1's PreparingForSleep read (Fingerprint.cpp:50-77), and never
# retries outside that path. fprintd is bus-activated; if it is slow or dead
# right then, the WARN is the only trace and the sensor stays dead for the
# whole lock (2026-09-27/28 lockouts, neither of them near a suspend). This
# background watcher is the only place that catches that failure for every
# lock, not just resumes.
#
# It also catches the other proven hang: handleUnlockSignal's SIGUSR1 path
# takes timersMutex from signal context and can deadlock against the timers
# thread (hyprlock.cpp:96-101,882-884), so "Unlocking with a SIGUSR1" can log
# five times with the process never actually exiting. Same remedy either
# way: replace the client, never unlock it ourselves.
#
# Runs in a subshell so it survives the exec below (separate process, not
# replaced by it). $$ here is this wrapper shell's PID, which exec turns
# into hyprlock's own PID, so it is exactly the PID hyprlock-resume-relock
# needs to verify against and replace. HYPRLOCK_ARMCHECK_TRIES bounds this to
# two replacements per lock chain; past that the mechanism stands down and
# leaves the session locked with the failure only in the log, per the never
# auto-unlock rule. No flock is taken here: the watcher never contends with
# the wrapper's own single-instance guard, and hyprlock-resume-relock's own
# PID-verified kill-and-restart is what actually enforces mutual exclusion.
if [ "${HYPRLOCK_ARMCHECK_TRIES:-0}" -lt 2 ]; then
    (
        # Load-bearing: this subshell inherits fd 9 (the wrapper's flock) from
        # the parent shell, open on hyprlock.lock. Without closing it here,
        # the watcher holds the single-instance lock for its entire life
        # (up to the whole lock session), even though it never calls flock
        # itself. When a wedge or dead-sensor fires and this watcher execs
        # hyprlock-resume-relock, that script kills the old hyprlock and
        # starts a fresh wrapper; that fresh wrapper's `flock -n 9` then
        # fails against this still-running watcher's copy of the fd, and it
        # silently exit-0s per line 6, leaving the session locked with no
        # lock client running at all: precisely the lockdead state this
        # whole mechanism exists to prevent. Closing the fd here costs the
        # watcher nothing, since it never takes the lock in the first place.
        exec 9>&-

        hyprlock_pid="$$"
        armed=-1
        wedged=0

        while /run/current-system/sw/bin/kill -0 "$hyprlock_pid" 2>/dev/null; do
            if [ "$armed" -eq -1 ]; then
                /run/current-system/sw/bin/sleep 8
                /run/current-system/sw/bin/kill -0 "$hyprlock_pid" 2>/dev/null || exit 0
                armed=0
                /run/current-system/sw/bin/grep -q "fprint: started verifying" "$log_file" && armed=1
                if [ "$armed" -eq 0 ]; then
                    break
                fi
                continue
            fi

            last_signal_line="$(/run/current-system/sw/bin/grep -n "Unlocking with a SIGUSR1" "$log_file" | /run/current-system/sw/bin/tail -n 1 | /run/current-system/sw/bin/sed -E 's/:.*//')"
            if [ -n "$last_signal_line" ]; then
                /run/current-system/sw/bin/tail -n "+$last_signal_line" "$log_file" | /run/current-system/sw/bin/grep -q "Unlocked, exiting!" || wedged=1
            fi
            [ "$wedged" -eq 1 ] && break

            /run/current-system/sw/bin/sleep 5
        done

        /run/current-system/sw/bin/kill -0 "$hyprlock_pid" 2>/dev/null || exit 0

        if [ "$armed" -eq 0 ] || [ "$wedged" -eq 1 ]; then
            HYPRLOCK_ARMCHECK_TRIES=$((${HYPRLOCK_ARMCHECK_TRIES:-0} + 1)) \
                /run/current-system/sw/bin/hyprlock-resume-relock --replace-pids "$hyprlock_pid"
        fi
    ) &
fi

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
