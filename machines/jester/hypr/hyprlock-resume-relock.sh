#!/run/current-system/sw/bin/bash
# Workaround for an upstream hyprlock bug (0.9.6), not a fix. Runs from
# hypridle's after_sleep_cmd on resume.
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

/run/current-system/sw/bin/hyprctl dispatch dpms on

if /run/current-system/sw/bin/pgrep -x hyprlock >/dev/null; then
    /run/current-system/sw/bin/pkill -KILL -x hyprlock
    # Wait for the flock on fd 9 to clear. If we start the wrapper too soon,
    # its single-instance guard sees the stale lock and exits 0, leaving no
    # lock client at all.
    for _ in $(/run/current-system/sw/bin/seq 1 40); do
        /run/current-system/sw/bin/pgrep -x hyprlock >/dev/null || break
        /run/current-system/sw/bin/sleep 0.25
    done
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

    # Give hyprlock up to ~3 seconds to actually appear.
    for _ in $(/run/current-system/sw/bin/seq 1 12); do
        if /run/current-system/sw/bin/pgrep -x hyprlock >/dev/null; then
            started=1
            break
        fi
        sleep 0.25
    done

    if [ "$started" -eq 1 ]; then
        break
    fi

    attempt=$((attempt + 1))
    sleep 0.5
done

if [ "$started" -eq 0 ]; then
    # All 3 attempts failed to bring up a lock client. The compositor is
    # already showing a blank, locked screen with nothing listening for
    # input: that is a worse outcome than an unlocked session, because a
    # blank screen with no lock client cannot be authenticated into at all
    # and traps the user. So log loudly, then fall back to unlocking the
    # session as a last resort rather than stranding the user forever.
    msg="resume-relock: hyprlock failed to start after $max_attempts attempts; unlocking session as last resort"
    if [ -x /run/current-system/sw/bin/systemd-cat ]; then
        echo "$msg" | /run/current-system/sw/bin/systemd-cat -t hyprlock-resume-relock -p err
    else
        /run/current-system/sw/bin/logger -t hyprlock-resume-relock -p err "$msg"
    fi
    # Only unlock if the session is really still locked. hyprlock-wrapper's own
    # EXIT trap already runs loginctl unlock-session whenever hyprlock exits or
    # fails to start, so by the time we get here the session is often already
    # unlocked. This guard avoids unlocking a session that was never locked
    # (or was already unlocked by the trap); it still lets the fallback fire
    # in the case that matters, where hyprlock is hung and never exits, so
    # the trap never ran and the session is still genuinely locked.
    locked="$(/run/current-system/sw/bin/loginctl show-session self -p LockedHint 2>/dev/null)"
    if [ "$locked" = "LockedHint=yes" ]; then
        /run/current-system/sw/bin/loginctl unlock-session
    else
        msg2="resume-relock: session already unlocked (LockedHint not yes), skipping fallback unlock"
        if [ -x /run/current-system/sw/bin/systemd-cat ]; then
            echo "$msg2" | /run/current-system/sw/bin/systemd-cat -t hyprlock-resume-relock -p info
        else
            /run/current-system/sw/bin/logger -t hyprlock-resume-relock -p info "$msg2"
        fi
    fi
fi
