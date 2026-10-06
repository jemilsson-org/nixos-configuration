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

# Verify-match unlock-hang watchdog. hyprlock can confirm a fingerprint
# match ("fprint: handling status verify-match", then "Authenticating") and
# then just hang instead of unlocking (observed live, 2026-10-06). Sending it
# SIGUSR1 here is not an auto-unlock: the fingerprint has already matched, and
# SIGUSR1 is hyprlock's own documented unlock signal (see the arm-check
# comment above re: handleUnlockSignal). This fires on verify-match and on
# nothing else. If SIGUSR1 itself also hangs (also observed live), the
# existing hyprlock-resume-relock --replace-pids path is reused rather than
# reimplemented: it already does the one safe kill-old/start-new sequence
# this whole file depends on (precondition check, SIGKILL, PID-verified wait,
# PID-verified start). Once the replacement is up, it is signalled too: the
# original match is still the reason this lock session is ending.
#
# Factored into a function, not inlined, so hyprlock-wrapper.test.sh can
# drive its state machine against fake kill/grep/pgrep/hyprlock-resume-relock
# without a real hyprlock or fprintd.
verifymatch_watch() {
    local hyprlock_pid="$1" log_file="$2"

    while /run/current-system/sw/bin/kill -0 "$hyprlock_pid" 2>/dev/null; do
        /run/current-system/sw/bin/grep -q "fprint: handling status verify-match" "$log_file" 2>/dev/null && break
        /run/current-system/sw/bin/sleep 1
    done
    /run/current-system/sw/bin/kill -0 "$hyprlock_pid" 2>/dev/null || return 0

    /run/current-system/sw/bin/sleep 3
    /run/current-system/sw/bin/kill -0 "$hyprlock_pid" 2>/dev/null || return 0
    /run/current-system/sw/bin/kill -USR1 "$hyprlock_pid" 2>/dev/null

    /run/current-system/sw/bin/sleep 3
    /run/current-system/sw/bin/kill -0 "$hyprlock_pid" 2>/dev/null || return 0

    HYPRLOCK_VERIFYMATCH_TRIES=$((${HYPRLOCK_VERIFYMATCH_TRIES:-0} + 1)) \
        /run/current-system/sw/bin/hyprlock-resume-relock --replace-pids "$hyprlock_pid" || return 1
    new_pids="$(/run/current-system/sw/bin/pgrep -x hyprlock || true)"
    for new_pid in $new_pids; do
        /run/current-system/sw/bin/kill -USR1 "$new_pid" 2>/dev/null
    done
}

if [ "${HYPRLOCK_VERIFYMATCH_TRIES:-0}" -lt 2 ]; then
    (
        exec 9>&-
        verifymatch_watch "$$" "$log_file"
    ) &
fi

# Bounded fprintd D-Bus activation before hyprlock claims the sensor.
# fprintd is inactive when idle; a slow activation during the initial PreparingForSleep
# handshake leaves hyprlock's one-time Fingerprint.cpp arming unretried (2026-10-05).
# GetDefaultDevice activates and warms fprintd without changing its D-Bus owner. Failure
# must not block locking, matching the never-auto-unlock and no-fprintd-restart rules.
/run/current-system/sw/bin/timeout 5 /run/current-system/sw/bin/busctl --system \
    call net.reactivated.Fprint /net/reactivated/Fprint/Manager \
    net.reactivated.Fprint.Manager GetDefaultDevice >>"$log_file" 2>&1 || \
    echo "$(/run/current-system/sw/bin/date -Iseconds) fprintd wake failed" >>"$log_file"

# fprintd idle-exits ~30s after activation (its own D-Bus service timeout),
# well inside a normal lock session. The one-shot wake above only guarantees
# the sensor is up at the moment hyprlock does its single Fingerprint.cpp
# arming; if the session sits locked longer than that, fprintd can exit from
# under an already-armed hyprlock too. Keep it alive for the whole lock
# session with a cheap periodic wake, same GetDefaultDevice call, same
# never-block/no-restart rules as the one above. Loops on kill -0 "$$" same
# as the arm-check watcher: $$ here is this wrapper's PID, which exec below
# turns into hyprlock's own PID, so the loop exits on its own once hyprlock
# is gone, with nothing left to reap.
(
    exec 9>&-
    hyprlock_pid="$$"
    while /run/current-system/sw/bin/sleep 10; do
        /run/current-system/sw/bin/kill -0 "$hyprlock_pid" 2>/dev/null || exit 0
        /run/current-system/sw/bin/timeout 5 /run/current-system/sw/bin/busctl --system \
            call net.reactivated.Fprint /net/reactivated/Fprint/Manager \
            net.reactivated.Fprint.Manager GetDefaultDevice >/dev/null 2>&1
    done
) &

# This trap does NOT run when hyprlock exits, crashes, or is killed. exec
# below replaces this shell's process image, and exec discards any pending
# trap along with the shell itself. The trap can only fire if exec fails to
# start hyprlock in the first place (binary missing or not executable), in
# which case this shell keeps running and the EXIT trap covers that one case.
# Deliberately no unlock here: by the time we reach this line, the flock
# above (line 6) is already held, so no other hyprlock instance is running;
# if exec then fails, hyprlock never started, no ext-session-lock client ever
# bound, and the compositor holds no lock object from this wrapper. There is
# nothing real to strand the user in. Per the never-auto-unlock rule, this
# case still just logs loudly and leaves the session locked (LockedHint
# stays set) rather than clearing it. Recovery: SUPER+SHIFT+CTRL+ALT+U, or
# `hyprlock-resume-relock` from another TTY. NOT `pkill -USR1`, which can
# deadlock in handleUnlockSignal (see arm-check comment above).
# No fprintd restart: fprintd drops a claim when its D-Bus owner exits, and
# hyprlock never reconnects to a restarted fprintd.
trap 'echo "$(/run/current-system/sw/bin/date -Iseconds) exec failed to start hyprlock; session remains locked" >>"$log_file"' EXIT
exec /run/current-system/sw/bin/hyprlock "$@" >>"$log_file" 2>&1
