#!/usr/bin/env python3
"""Hermetic test for presence-lock.py: fakes gst-launch-1.0 and loginctl on
PATH so no real camera or session is touched. See presence-lock.nix for the
production wiring this stands in for.

Case 1: blank BGR frames, no resume -> lock.
Case 2: gst-launch exits non-zero (camera busy) -> fail open, no lock.
Case 3: blank BGR frames but resumed marker touched after start -> no lock.
Case 4: a face-bearing frame after settle -> pipeline terminated early, no
        lock. The fake gst-launch emits blank frames then one face frame
        then more blanks; we check the script stopped reading before the
        end (early termination) and did not lock.
Case 5: swaylock.lock is held (flock) -> script exits 0 immediately,
        gst-launch is NOT called.
Case 6: loginctl returns LockedHint "yes" -> script exits 0 immediately,
        no lock, and the fake gst was never invoked.
"""
import os
import stat
import subprocess
import sys
import tempfile
import time

import cv2
import numpy as np

WIDTH, HEIGHT, NUM_BUFFERS = 640, 360, 20
HERE = os.path.dirname(os.path.abspath(__file__))


def make_face_frame(lena_path):
    """Load lena.jpg, resize to WIDTHxHEIGHT, return BGR bytes."""
    img = cv2.imread(lena_path)
    if img is None:
        raise RuntimeError(f"failed to load {lena_path}")
    img = cv2.resize(img, (WIDTH, HEIGHT))
    return img.tobytes()


def write_exe(path, contents):
    with open(path, "w") as f:
        f.write(contents)
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


def make_fakes(bindir, calls_file, gst_mode, face_frame):
    """gst_mode: 'blank' for all-zero frames, 'error' for exit 1, 'face' for
    blank frames then a face frame then more blanks."""
    frame_size = WIDTH * HEIGHT * 3
    blank = b"\x00" * frame_size

    frames_file = os.path.join(bindir, "frames.bin")
    if gst_mode == "error":
        gst_body = (f"#!/bin/sh\necho 'gst-launch' >> \"{calls_file}\"\n"
                    f"echo 'fake gst-launch: camera busy' >&2\nexit 1\n")
    elif gst_mode == "blank":
        with open(frames_file, "wb") as f:
            f.write(blank * NUM_BUFFERS)
        gst_body = f"#!/bin/sh\necho 'gst-launch' >> \"{calls_file}\"\ncat {frames_file}\n"
    elif gst_mode == "face":
        # 5 blank settle frames, 1 face frame, then 14 more blanks.
        # The script should terminate after the face frame, before the rest.
        with open(frames_file, "wb") as f:
            f.write((blank * 5) + face_frame + (blank * 14))
        gst_body = f"#!/bin/sh\necho 'gst-launch' >> \"{calls_file}\"\ncat {frames_file}\n"
    else:
        raise ValueError(gst_mode)
    write_exe(os.path.join(bindir, "gst-launch-1.0"), gst_body)

    # Records every call; answers LockedHint "no" so the script proceeds.
    loginctl_body = f"""#!/bin/sh
    echo "$*" >> "{calls_file}"
    case "$1 $2" in
      "show-session self") echo no ;;
    esac
    """
    write_exe(os.path.join(bindir, "loginctl"), loginctl_body)


def make_fakes_session_locked(bindir, calls_file):
    """Fake loginctl that returns LockedHint 'yes' (session already locked)."""
    loginctl_body = f"""#!/bin/sh
    echo "$*" >> "{calls_file}"
    case "$1 $2" in
      "show-session self") echo yes ;;
    esac
    """
    write_exe(os.path.join(bindir, "loginctl"), loginctl_body)
    # gst-launch should never be called; but provide a stub that would fail if called
    gst_body = f"#!/bin/sh\necho 'gst-launch' >> \"{calls_file}\"\necho 'gst-launch should not be called' >&2\nexit 1\n"
    write_exe(os.path.join(bindir, "gst-launch-1.0"), gst_body)


def run_case(model_path, lena_path, gst_mode, resume_after_start=False,
             extra_args=None, hold_swaylock=False, session_locked=False):
    with tempfile.TemporaryDirectory() as td:
        bindir = os.path.join(td, "bin")
        os.makedirs(bindir)
        calls_file = os.path.join(td, "calls.log")
        open(calls_file, "w").close()

        face_frame = make_face_frame(lena_path)

        if session_locked:
            make_fakes_session_locked(bindir, calls_file)
        else:
            make_fakes(bindir, calls_file, gst_mode, face_frame)

        resumed_file = os.path.join(td, "presence-lock.resumed")
        env = dict(os.environ)
        env["PATH"] = bindir + ":" + env["PATH"]
        env["XDG_RUNTIME_DIR"] = td

        # If requested, hold flock on the swaylock.lock file in a child
        # process so presence-lock.py sees it as already held.
        lock_holder = None
        if hold_swaylock:
            lock_path = os.path.join(td, "swaylock.lock")
            lock_holder = subprocess.Popen(
                [sys.executable, "-c",
                 f"import fcntl, os, time; "
                 f"fd = os.open({lock_path!r}, os.O_RDWR | os.O_CREAT, 0o600); "
                 f"fcntl.flock(fd, fcntl.LOCK_EX); "
                 f"print('held', flush=True); "
                 f"time.sleep(60)"],
                stdout=subprocess.PIPE,
            )
            lock_holder.stdout.readline()  # wait until lock is held

        cmd = [
            sys.executable, os.path.join(HERE, "presence-lock.py"),
            "--model", model_path, "--width", str(WIDTH), "--height", str(HEIGHT),
            "--num-buffers", str(NUM_BUFFERS), "--timeout", "120",
            "--settle-frames", "3",
            "--resumed-file", resumed_file,
        ]
        if extra_args:
            cmd.extend(extra_args)

        proc = subprocess.Popen(cmd, env=env, stderr=subprocess.PIPE)
        if resume_after_start:
            time.sleep(0.2)
            with open(resumed_file, "w") as f:
                f.write("")
            future = time.time() + 2
            os.utime(resumed_file, (future, future))
        stderr = proc.stderr.read().decode(errors="replace") if proc.stderr else ""
        proc.wait(timeout=60)

        # Kill the lock holder if we started one.
        if lock_holder:
            lock_holder.kill()
            lock_holder.wait()

        calls = open(calls_file).read()
        locked = "lock-session" in calls
        return proc.returncode, locked, stderr, calls


def main():
    model_path = sys.argv[1]
    lena_path = sys.argv[2]

    # Case 1: no face, no resume -> lock.
    rc, locked, err, calls = run_case(model_path, lena_path, gst_mode="blank")
    assert rc == 0, f"blank case: expected exit 0, got {rc}: {err}"
    assert locked, f"blank case: expected lock-session, none logged: {err}"

    # Case 2: camera unreadable -> fail open, no lock.
    rc, locked, err, calls = run_case(model_path, lena_path, gst_mode="error")
    assert rc == 0, f"camera-busy case: expected exit 0, got {rc}: {err}"
    assert not locked, f"camera-busy case: lock-session must NOT be called: {err}"

    # Case 3: no face, but resumed during check -> no lock.
    rc, locked, err, calls = run_case(model_path, lena_path, gst_mode="blank",
                               resume_after_start=True)
    assert rc == 0, f"resumed case: expected exit 0, got {rc}: {err}"
    assert not locked, f"resumed case: lock-session must NOT be called: {err}"
    assert "resumed=True" in err, f"resumed case: expected resumed=True in log: {err}"

    # Case 4: face on an early post-settle frame -> no lock, pipeline
    # terminated early (frames_seen < NUM_BUFFERS).
    rc, locked, err, calls = run_case(model_path, lena_path, gst_mode="face")
    assert rc == 0, f"face case: expected exit 0, got {rc}: {err}"
    assert not locked, f"face case: lock-session must NOT be called: {err}"
    assert "face=True" in err, f"face case: expected face=True in log: {err}"
    # The face is frame 6 (0-indexed 5), so frames_seen should be 6, well
    # under NUM_BUFFERS=20.
    assert "frames=6" in err, f"face case: expected frames=6 (early stop), got: {err}"

    # Case 5: swaylock already holding the lock file -> script exits early
    # without touching the camera.
    rc, locked, err, calls = run_case(model_path, lena_path, gst_mode="blank",
                                hold_swaylock=True)
    assert rc == 0, f"already-locked case: expected exit 0, got {rc}: {err}"
    assert not locked, f"already-locked case: lock-session must NOT be called: {err}"
    assert "swaylock already active" in err, \
        f"already-locked case: expected early-exit log, got: {err}"

    # Case 6: loginctl returns LockedHint 'yes' -> script exits early
    # without touching the camera.
    rc, locked, err, calls = run_case(model_path, lena_path, gst_mode="blank",
                                session_locked=True)
    assert rc == 0, f"session-locked case: expected exit 0, got {rc}: {err}"
    assert not locked, f"session-locked case: lock-session must NOT be called: {err}"
    assert "session already locked" in err, \
        f"session-locked case: expected early-exit log, got: {err}"
    assert "gst-launch" not in calls, f"session-locked case: gst-launch must NOT be called: {calls}"

    print("presence-lock-test: ok")


if __name__ == "__main__":
    main()
