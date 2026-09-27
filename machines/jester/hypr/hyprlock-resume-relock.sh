#!/run/current-system/sw/bin/bash
# Workaround for an upstream hyprlock bug (0.9.6), not a fix. Runs from
# hypridle's after_sleep_cmd on resume, and also invoked directly by
# hyprlock-wrapper's arm-check watcher (--replace-pids) after every lock,
# whether or not a suspend was involved: the same "sensor never armed" and
# "SIGUSR1 unlock deadlock" failures both happen on plain idle locks.
#
# Observed, not inferred: hyprlock arms the fingerprint reader correctly at
# lock time (fprint: started verifying, within 1s). On suspend/resume it logs
# "fprint: PrepareForSleep (start: true)" then "(start: false)" and never
# re-issues VerifyStart; the sensor is then dead for the rest of the session.
# Password auth breaks across the same boundary too (an earlier instance logged
# hyprlock's own "Invalid key down event (key already pressed?)" right before
# its pam_unix failures), so after one resume NEITHER auth method works and
# the user is locked out entirely.
#
# Fix: replace the process outright. A fresh hyprlock arms the sensor from
# scratch and starts with clean keyboard state.
#
# This never exposes the desktop: ext-session-lock-v1 requires the compositor
# to KEEP the session locked when the lock client dies without unlocking, and
# Hyprland's misc:allow_session_lock_restore = true (hyprland.lua) lets the
# replacement client take the lock back over.
#
# misc:allow_session_lock_restore defaults to false. Without it, a replacement
# lock client gets sendDenied/finished and exits, leaving a lockdead screen.
# This workaround depends on it being set to true (~/.config/hypr/hyprland.lua:109).
#
# misc:lockdead_screen_delay is set to 0 in hyprland.lua. At its default of
# 1000ms, Renderer.cpp renders the real desktop between the new lock client
# binding and its surface mapping, because shallConsiderLockMissing() goes
# false as soon as a lock object exists.
#
# SIGKILL specifically, not SIGTERM or SIGUSR1: both of those are hyprlock's
# own *unlock* paths and would drop the session lock instead of replacing it.
set -u

log_err() {
    if [ -x /run/current-system/sw/bin/systemd-cat ]; then
        echo "$1" | /run/current-system/sw/bin/systemd-cat -t hyprlock-resume-relock -p err
    else
        /run/current-system/sw/bin/logger -t hyprlock-resume-relock -p err "$1"
    fi
}

# Check the two Hyprland options this whole workaround depends on before we
# kill anything. If the compositor will not actually restore the lock (either
# option missing or wrong), killing the running hyprlock opens the exact
# desktop-exposure window this script exists to prevent: better to leave the
# existing (broken-auth) lock client in place than to gamble on a compositor
# that will not take the replacement back. Prefer jq if present; fall back to
# grep/sed rather than pull in a new dependency.
check_option() {
    opt="$1"
    want="$2"
    json=""
    # hyprctl talks to Hyprland over its IPC socket, which can be briefly
    # unavailable right at resume. Retry a few times before giving up, so one
    # flaky call does not abort the whole relock and strand the user behind
    # the old, auth-broken hyprlock.
    for _ in 1 2 3 4 5; do
        json="$(/run/current-system/sw/bin/hyprctl getoption "$opt" -j 2>/dev/null)" && [ -n "$json" ] && break
        json=""
        /run/current-system/sw/bin/sleep 0.25
    done
    [ -n "$json" ] || return 1
    if [ -x /run/current-system/sw/bin/jq ]; then
        val="$(echo "$json" | /run/current-system/sw/bin/jq -r '.int // .str // empty' 2>/dev/null)" || return 1
    else
        val="$(echo "$json" | /run/current-system/sw/bin/grep -o '"int"[[:space:]]*:[[:space:]]*[-0-9]*' | /run/current-system/sw/bin/sed -E 's/.*:[[:space:]]*//')"
    fi
    [ -n "$val" ] || return 1
    [ "$val" = "$want" ]
}

if ! check_option misc:allow_session_lock_restore 1; then
    log_err "resume-relock: misc:allow_session_lock_restore is not verifiably true; refusing to kill hyprlock (compositor would not restore the lock)"
    exit 1
fi
if ! check_option misc:lockdead_screen_delay 0; then
    log_err "resume-relock: misc:lockdead_screen_delay is not verifiably 0; refusing to kill hyprlock (desktop could render before the replacement binds)"
    exit 1
fi

/run/current-system/sw/bin/hyprctl dispatch dpms on

# --replace-pids from the arm-check watcher hands us the exact PID it
# already verified is stuck (dead sensor or wedged SIGUSR1 unlock), so we
# don't re-derive it with pgrep: pgrep here could also catch a second,
# unrelated hyprlock that raced in between the watcher's check and this
# call, and killing that one would be a plain misfire.
if [ "${1:-}" = "--replace-pids" ]; then
    old_pids="$2"
    shift 2
else
    old_pids="$(/run/current-system/sw/bin/pgrep -x hyprlock || true)"
fi

if [ -n "$old_pids" ]; then
    /run/current-system/sw/bin/pkill -KILL -x hyprlock
    # Wait on the specific old PIDs, not on the process name. Waiting on the
    # name is what let a stuck old hyprlock (e.g. blocked in D state on the
    # fingerprint ioctl) be mistaken for gone: the name check just times out
    # silently and the start loop below can then match that same stale,
    # auth-broken process and call it success.
    for _ in $(/run/current-system/sw/bin/seq 1 40); do
        still=0
        for pid in $old_pids; do
            /run/current-system/sw/bin/kill -0 "$pid" 2>/dev/null && still=1
        done
        [ "$still" -eq 1 ] || break
        /run/current-system/sw/bin/sleep 0.25
    done

    surviving=""
    for pid in $old_pids; do
        /run/current-system/sw/bin/kill -0 "$pid" 2>/dev/null && surviving="$surviving $pid"
    done
    if [ -n "$surviving" ]; then
        log_err "resume-relock: old hyprlock PID(s)$surviving still alive after SIGKILL and 10s wait; the kill did not take effect. Not starting a replacement, since the flock on fd 9 would make it a silent no-op against the surviving process."
        exit 1
    fi
fi

# The flock on fd 9 (in hyprlock-wrapper) releases the instant the old
# process dies. Two wrapper invocations could in principle race right after
# that. The flock guard is still safe: the loser just exits 0 harmlessly,
# it does not kill the winner's hyprlock.

attempt=1
max_attempts=3
started=0

while [ "$attempt" -le "$max_attempts" ]; do
    /run/current-system/sw/bin/hyprlock-wrapper &

    # Give hyprlock up to ~3 seconds to actually appear. A pgrep hit on one of
    # the old PIDs must not count: if the earlier kill did not fully take
    # effect this would otherwise report success while the stale, auth-broken
    # process is still what's showing.
    for _ in $(/run/current-system/sw/bin/seq 1 12); do
        new_pids="$(/run/current-system/sw/bin/pgrep -x hyprlock || true)"
        for pid in $new_pids; do
            case " $old_pids " in
                *" $pid "*) ;;
                *) started=1 ;;
            esac
        done
        [ "$started" -eq 1 ] && break
        sleep 0.25
    done

    if [ "$started" -eq 1 ]; then
        break
    fi

    attempt=$((attempt + 1))
    sleep 0.5
done

if [ "$started" -eq 0 ]; then
    # All 3 attempts failed to bring up a lock client. Dropping the session
    # lock here without authenticating the user would be a lock bypass, so
    # this script never does that, no matter how long the screen stays
    # blank. Log loudly and leave the session locked; exit non-zero so the
    # failure shows up as a failed unit too.
    #
    # Two recovery routes exist from this state, and this comment is the
    # only place they are written down:
    #   1. SUPER + SHIFT + CTRL + ALT + U (~/.config/hypr/hyprland.lua),
    #      which calls hl.clear_crashed_lockscreen(). This only works when
    #      no live lock client still holds the lock.
    #   2. Switch to another TTY and run: hyprlock-resume-relock
    #      Not pkill -USR1 -x hyprlock: handleUnlockSignal takes timersMutex
    #      from signal-handler context and can deadlock against the timers
    #      thread, so SIGUSR1 can log "Unlocking with a SIGUSR1" and then
    #      just sit there forever instead of exiting (verified 2026-09-28,
    #      PID 913371, five times). hyprlock-resume-relock SIGKILLs and
    #      verifies by PID instead, which isn't subject to that hang.
    msg="resume-relock: hyprlock failed to start after $max_attempts attempts; leaving session LOCKED with no lock client running (deliberate, no auto-unlock). Recover via SUPER+SHIFT+CTRL+ALT+U, or from another TTY: hyprlock-resume-relock (not pkill -USR1 -x hyprlock, which can deadlock)"
    log_err "$msg"
    exit 1
fi
