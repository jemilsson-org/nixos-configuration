#!/usr/bin/env python3
"""Presence-based auto-lock: one-shot check, run on-demand by a hypridle
listener (see hypr/hypridle.conf), not a long-running daemon.

Touches the webcam only for the few seconds this check needs, then lets it
go: libcamera is single-consumer, so a permanently-open feed (the old
presence-lock-feed.service) blocked every other app from the camera. This
spawns a short gst-launch pipeline that streams raw frames straight off
the shared PipeWire camera node, runs face detection per frame after a
short auto-exposure settle, and terminates the pipeline as soon as a face
is found - so only then does it decide whether to lock. No frames, an unreadable camera, or a timeout (e.g. a video call
already holds the camera) all fail open: log and exit without locking. See
presence-lock.nix for the packaging and why libcamera forces this route
instead of a plain cv2.VideoCapture.

If the user becomes active while the check runs, hypridle resumes the
listener and on-resume touches $XDG_RUNTIME_DIR/presence-lock.resumed; the
script checks that file's mtime before locking and skips the lock if it is
newer than the check start (the race between the check finishing and the
user returning to the keyboard).

Each run logs a start line and a summary line (face, frames read,
resumed-during-check, decision) to stderr, which hypridle's children send
to the user journal.
"""
import argparse
import fcntl
import os
import subprocess
import sys
import time

import cv2
import numpy as np

# The YuNet ONNX model path is passed in explicitly by presence-lock.nix
# (--model); nixpkgs' opencv4 python bindings ship no model data.

# YuNet thresholds: score 0.6 (below the 0.9 default, biased toward seeing a
# face), NMS 0.3, keep at most 50 candidates (we need only one).
YUNET_SCORE_THRESHOLD = 0.6
YUNET_NMS_THRESHOLD = 0.3
YUNET_TOP_K = 50


def log(msg: str) -> None:
    print(f"presence-lock: {msg}", file=sys.stderr)


def session_locked() -> bool:
    """True if the session is already locked (or lock state can't be
    determined - fail closed here too, i.e. skip rather than lock a session
    we can't confirm is unlocked)."""
    try:
        out = subprocess.run(
            ["loginctl", "show-session", "self", "-p", "LockedHint", "--value"],
            capture_output=True, text=True, timeout=5,
        )
        return out.stdout.strip() != "no"
    except Exception as e:
        log(f"loginctl check failed, skipping: {e}")
        return True


def swaylock_holding() -> bool:
    """Non-blocking flock test on $XDG_RUNTIME_DIR/swaylock.lock.

    hypridle's lock_cmd runs `flock -n $XDG_RUNTIME_DIR/swaylock.lock
    swaylock -f`, so while swaylock is active the lock file is held
    exclusively.  We try a non-blocking shared lock: if it fails the lock
    screen is up and we must not touch the camera."""
    lock_path = os.path.join(
        os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"),
        "swaylock.lock",
    )
    try:
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    except OSError:
        return False  # no file yet -> swaylock not running
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False  # we got the lock -> swaylock is NOT active
    except (BlockingIOError, OSError):
        return True  # lock held -> swaylock IS active
    finally:
        os.close(fd)


def stream_and_detect(detector: "cv2.FaceDetectorYN", gst_launch: str,
                          target_object: str, width: int, height: int,
                          num_buffers: int, timeout: float,
                          settle_frames: int) -> tuple:
    """Streams BGR frames from a gst-launch pipeline, runs YuNet detection
    per frame after `settle_frames` for auto-exposure, and terminates the
    pipeline as soon as a face is found.

    Returns (face_seen, frames_seen, error). On any failure to start or read
    the pipeline (camera busy, missing, timed out), returns (False, n, True)
    so the caller fails open without locking. `num_buffers` is the upper
    bound on frames the pipeline will emit; the overall `timeout` caps the
    whole read."""
    frame_size = width * height * 3
    cmd = [
        gst_launch, "-q",
        "pipewiresrc", f"target-object={target_object}", f"num-buffers={num_buffers}",
        "!", "videoconvert",
        "!", "videoscale",
        "!", f"video/x-raw,format=BGR,width={width},height={height}",
        "!", "fdsink", "fd=1",
    ]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError:
        log(f"gst-launch binary not found: {gst_launch}")
        return False, 0, True
    except Exception as e:
        log(f"gst-launch failed to start: {e}")
        return False, 0, True

    deadline = time.time() + timeout
    buf = bytearray()
    consumed = 0  # bytes already turned into frames
    frames_seen = 0
    face_seen = False
    try:
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                log("gst-launch timed out, camera unreadable")
                return False, frames_seen, True
            # Read up to one frame's worth (or the remainder of a partial frame).
            want = frame_size - ((len(buf) - consumed) % frame_size)
            chunk = proc.stdout.read(want)
            if not chunk:
                # Pipeline closed stdout: either finished (num_buffers reached)
                # or exited. Check return code for a real error below.
                break
            buf.extend(chunk)
            while (len(buf) - consumed) >= frame_size:
                frame = np.frombuffer(
                    bytes(buf[consumed:consumed + frame_size]),
                    dtype=np.uint8,
                ).reshape(height, width, 3)
                consumed += frame_size
                frames_seen += 1
                # Drop processed bytes to bound memory.
                if consumed > 65536:
                    del buf[:consumed]
                    consumed = 0
                # Skip the first `settle_frames` for auto-exposure to settle,
                # matching the old any_face(frames[-5:]) behaviour.
                if frames_seen <= settle_frames:
                    continue
                faces = detector.detect(frame)[1]
                if faces is not None and len(faces) > 0:
                    face_seen = True
                    proc.terminate()
                    try:
                        proc.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
                    return True, frames_seen, False
    except Exception as e:
        log(f"error reading gst-launch: {e}")
        proc.kill()
        proc.wait()
        return False, frames_seen, True

    # Pipeline closed stdout normally (num_buffers reached) without a face.
    rc = proc.wait()
    if rc != 0:
        err = proc.stderr.read().decode(errors="replace").strip()
        log(f"gst-launch exited {rc}: {err}")
        return False, frames_seen, True
    return face_seen, frames_seen, False


def resumed_during_check(resumed_file: str, start: float) -> bool:
    """True if the on-resume marker was touched after the check started."""
    try:
        mtime = os.path.getmtime(resumed_file)
    except FileNotFoundError:
        return False
    except OSError as e:
        # Unreadable marker: treat as not resumed (fail toward the existing
        # behaviour, i.e. let the face result decide).
        log(f"could not stat {resumed_file}: {e}")
        return False
    return mtime > start


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--gst-launch", default="gst-launch-1.0", help="gst-launch-1.0 binary")
    ap.add_argument("--target-object", default="libcamera_input.__SB_.PC00.LNK1",
                     help="PipeWire camera node name")
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--height", type=int, default=360)
    ap.add_argument("--num-buffers", type=int, default=20, help="upper bound on frames to capture")
    ap.add_argument("--settle-frames", type=int, default=15,
                    help="frames to skip before running detection (auto-exposure settle)")
    ap.add_argument("--timeout", type=float, default=10.0, help="seconds to wait for gst-launch")
    ap.add_argument("--model", required=True, help="path to the YuNet ONNX model file")
    ap.add_argument("--resumed-file",
                    default=os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/run/user/1000"),
                                         "presence-lock.resumed"),
                    help="path to the on-resume marker touched by hypridle")
    args = ap.parse_args()

    # If swaylock is already holding the lock file, the lock screen is up.
    # Exit immediately without touching the webcam.
    if swaylock_holding():
        log("swaylock already active, skipping check")
        return 0

    if session_locked():
        log("session already locked, skipping check")
        return 0

    start = time.time()
    log(f"start target={args.target_object} model={args.model}")

    try:
        detector = cv2.FaceDetectorYN.create(
            args.model, "", (args.width, args.height),
            YUNET_SCORE_THRESHOLD, YUNET_NMS_THRESHOLD, YUNET_TOP_K,
        )
    except Exception as e:
        log(f"failed to load YuNet model, not locking: {e}")
        return 0

    face, frames_seen, cam_error = stream_and_detect(
        detector, args.gst_launch, args.target_object, args.width, args.height,
        args.num_buffers, args.timeout, args.settle_frames,
    )
    if cam_error or frames_seen == 0:
        # Camera unreadable (busy, missing, timed out): fail open, no lock.
        log(f"camera unavailable (frames_seen={frames_seen}), not locking")
        return 0

    resumed = resumed_during_check(args.resumed_file, start)
    if face:
        decision = "skip (face)"
    elif resumed:
        decision = "skip (resumed during check)"
    else:
        decision = None
    log(f"face={face} frames={frames_seen} resumed={resumed} "
        f"decision={decision or 'lock'}")
    if decision:
        return 0

    if session_locked():
        return 0

    try:
        subprocess.run(["loginctl", "lock-session"], timeout=5, check=False)
    except Exception as e:
        log(f"lock-session failed: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
