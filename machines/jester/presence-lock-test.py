#!/usr/bin/env python3
"""Hermetic test for presence-lock.py: fakes gst-launch-1.0, loginctl and
fprintd-verify on PATH so no real camera, fingerprint reader or session is
touched. See presence-lock.nix for the production wiring this stands in for.

Case 1: blank frames, no fingerprint, no resume -> lock.
Case 2: gst-launch exits non-zero (camera busy) -> fail open, no lock.
Case 3: blank frames but resumed marker touched after start -> no lock.
Case 4: blank frames, fprintd-verify reports verify-match -> no lock.
Case 5: blank frames, fprintd-verify reports no match -> lock.
Case 7: frames too dark to judge (mean grey 14) -> fail open, no lock.
Case 8: resumed marker touched after the decision but before lock-session
         (the 150 ms race seen live) -> no lock.
Case 6: a face-bearing frame after settle -> pipeline terminated early, no
         lock. The fake gst-launch emits blank frames then one face frame
         then more blanks; we check the script stopped reading before the
         end (early termination) and did not lock.
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


def make_face_frame():
    """Draws a synthetic face that the Haar cascade detects (verified
    live: 1 face at (237,94,167,167))."""
    img = np.full((HEIGHT, WIDTH), 160, np.uint8)
    cv2.ellipse(img, (320, 180), (70, 90), 0, 0, 360, 210, -1)
    cv2.circle(img, (295, 160), 8, 40, -1)
    cv2.circle(img, (345, 160), 8, 40, -1)
    cv2.ellipse(img, (295, 160), (15, 12), 0, 0, 360, 100, -1)
    cv2.ellipse(img, (345, 160), (15, 12), 0, 0, 360, 100, -1)
    cv2.rectangle(img, (315, 165), (325, 200), 190, -1)
    cv2.ellipse(img, (320, 215), (20, 8), 0, 0, 360, 90, -1)
    cv2.rectangle(img, (250, 85), (390, 140), 80, -1)
    cv2.rectangle(img, (278, 148), (312, 154), 60, -1)
    cv2.rectangle(img, (328, 148), (362, 154), 60, -1)
    return img.tobytes()


def write_exe(path, contents):
    with open(path, "w") as f:
        f.write(contents)
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


def make_fakes(bindir, calls_file, gst_mode, fprintd_match, late_resume_file=None):
    """gst_mode: 'blank' for all-zero frames, 'error' for exit 1, 'face' for
    blank frames then a face frame then more blanks."""
    frame_size = WIDTH * HEIGHT
    # Mid-grey, above --min-luma: a lit room with nobody in it.
    blank = b"\x80" * frame_size
    face = make_face_frame()

    frames_file = os.path.join(bindir, "frames.bin")
    if gst_mode == "error":
        gst_body = "#!/bin/sh\necho 'fake gst-launch: camera busy' >&2\nexit 1\n"
    elif gst_mode == "dark":
        rng = np.random.default_rng(0)
        with open(frames_file, "wb") as f:
            f.write(rng.integers(9, 21, frame_size * NUM_BUFFERS, dtype=np.uint8).tobytes())
        gst_body = f"#!/bin/sh\ncat {frames_file}\n"
    elif gst_mode == "blank":
        with open(frames_file, "wb") as f:
            f.write(blank * NUM_BUFFERS)
        gst_body = f"#!/bin/sh\ncat {frames_file}\n"
    elif gst_mode == "face":
        # 5 blank settle frames, 1 face frame, then 14 more blanks.
        # The script should terminate after the face frame, before the rest.
        with open(frames_file, "wb") as f:
            f.write((blank * 5) + face + (blank * 14))
        gst_body = f"#!/bin/sh\ncat {frames_file}\n"
    else:
        raise ValueError(gst_mode)
    write_exe(os.path.join(bindir, "gst-launch-1.0"), gst_body)

    # Records every call; answers LockedHint "no" so the script proceeds.
    # With late_resume_file, the LockedHint query (made after the decision)
    # also touches the resume marker: user activity landing in the gap
    # between decision and lock-session.
    touch = f'touch "{late_resume_file}"; ' if late_resume_file else ""
    loginctl_body = f"""#!/bin/sh
echo "$*" >> "{calls_file}"
case "$1 $2" in
  "show-session self") {touch}echo no ;;
esac
"""
    write_exe(os.path.join(bindir, "loginctl"), loginctl_body)

    # fprintd-verify prints "Verify result: verify-match (...)" on match,
    # "Verify result: verify-no-match (...)" otherwise (per fprintd source).
    if fprintd_match:
        fprintd_body = "#!/bin/sh\necho 'Verify result: verify-match (done)'\nexit 0\n"
    else:
        fprintd_body = "#!/bin/sh\necho 'Verify result: verify-no-match (done)'\nexit 1\n"
    write_exe(os.path.join(bindir, "fprintd-verify"), fprintd_body)


def run_case(cascade, gst_mode, fprintd_match, resume_after_start=False,
             late_resume=False, extra_args=None):
    with tempfile.TemporaryDirectory() as td:
        bindir = os.path.join(td, "bin")
        os.makedirs(bindir)
        calls_file = os.path.join(td, "calls.log")
        open(calls_file, "w").close()
        resumed_file = os.path.join(td, "presence-lock.resumed")
        make_fakes(bindir, calls_file, gst_mode, fprintd_match,
                   resumed_file if late_resume else None)
        env = dict(os.environ)
        env["PATH"] = bindir + ":" + env["PATH"]
        env["XDG_RUNTIME_DIR"] = td

        cmd = [
            sys.executable, os.path.join(HERE, "presence-lock.py"),
            "--cascade", cascade, "--width", str(WIDTH), "--height", str(HEIGHT),
            "--num-buffers", str(NUM_BUFFERS), "--timeout", "10",
            "--settle-frames", "3",
            "--fp-grace", "2",
            "--resume-grace", "0.1",
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

        calls = open(calls_file).read()
        locked = "lock-session" in calls
        return proc.returncode, locked, stderr


def main():
    cascade = sys.argv[1]

    # Case 1: no face, no fingerprint, no resume -> lock.
    rc, locked, err = run_case(cascade, gst_mode="blank", fprintd_match=False)
    assert rc == 0, f"blank case: expected exit 0, got {rc}: {err}"
    assert locked, f"blank case: expected lock-session, none logged: {err}"

    # Case 2: camera unreadable -> fail open, no lock.
    rc, locked, err = run_case(cascade, gst_mode="error", fprintd_match=False)
    assert rc == 0, f"camera-busy case: expected exit 0, got {rc}: {err}"
    assert not locked, f"camera-busy case: lock-session must NOT be called: {err}"

    # Case 3: no face, but resumed during check -> no lock.
    rc, locked, err = run_case(cascade, gst_mode="blank", fprintd_match=False,
                               resume_after_start=True)
    assert rc == 0, f"resumed case: expected exit 0, got {rc}: {err}"
    assert not locked, f"resumed case: lock-session must NOT be called: {err}"
    assert "resumed=True" in err, f"resumed case: expected resumed=True in log: {err}"

    # Case 4: no face, fingerprint match -> no lock.
    rc, locked, err = run_case(cascade, gst_mode="blank", fprintd_match=True)
    assert rc == 0, f"fprintd-match case: expected exit 0, got {rc}: {err}"
    assert not locked, f"fprintd-match case: lock-session must NOT be called: {err}"
    assert "fingerprint=match" in err, f"fprintd-match case: expected fingerprint=match: {err}"

    # Case 5: no face, fprintd no match -> lock.
    rc, locked, err = run_case(cascade, gst_mode="blank", fprintd_match=False)
    assert rc == 0, f"fprintd-no-match case: expected exit 0, got {rc}: {err}"
    assert locked, f"fprintd-no-match case: lock-session must be called: {err}"

    # Case 6: face on an early post-settle frame -> no lock, pipeline
    # terminated early (frames_seen < NUM_BUFFERS).
    rc, locked, err = run_case(cascade, gst_mode="face", fprintd_match=False)
    assert rc == 0, f"face case: expected exit 0, got {rc}: {err}"
    assert not locked, f"face case: lock-session must NOT be called: {err}"
    assert "face=True" in err, f"face case: expected face=True in log: {err}"
    # The face is frame 6 (0-indexed 5), so frames_seen should be 6, well
    # under NUM_BUFFERS=20.
    assert "frames=6" in err, f"face case: expected frames=6 (early stop), got: {err}"

    # Case 7: too dark to judge -> fail open, no lock.
    rc, locked, err = run_case(cascade, gst_mode="dark", fprintd_match=False)
    assert rc == 0, f"dark case: expected exit 0, got {rc}: {err}"
    assert not locked, f"dark case: lock-session must NOT be called: {err}"
    assert "decision=skip (too dark)" in err, f"dark case: expected too-dark skip: {err}"

    # Case 8: resume lands after the decision, before lock-session -> no lock.
    rc, locked, err = run_case(cascade, gst_mode="blank", fprintd_match=False,
                               late_resume=True)
    assert rc == 0, f"late-resume case: expected exit 0, got {rc}: {err}"
    assert "resumed=False decision=lock" in err, f"late-resume case: decision should be lock: {err}"
    assert not locked, f"late-resume case: lock-session must NOT be called: {err}"
    assert "resumed before lock" in err, f"late-resume case: expected re-check log: {err}"

    print("presence-lock-test: ok")


if __name__ == "__main__":
    main()