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

While the face check runs, fprintd-verify runs concurrently; a fingerprint
match also prevents the lock. If fprintd is absent or errors (no finger
enrolled, no reader, polkit deny), it is ignored and the face result decides.

If the user becomes active while the check runs, hypridle resumes the
listener and on-resume touches $XDG_RUNTIME_DIR/presence-lock.resumed; the
script checks that file's mtime before locking and skips the lock if it is
newer than the check start (the race between the check finishing and the
user returning to the keyboard).

Each run logs a start line and a summary line (face, frames read,
fingerprint result, resumed-during-check, decision) to stderr, which
hypridle's children send to the user journal.
"""
import argparse
import collections
import os
import subprocess
import sys
import time

import cv2
import numpy as np

# nixpkgs' opencv4 python bindings don't ship cv2.data (no bundled cascade
# dir), unlike upstream pip wheels, so the cascade path is passed in
# explicitly by presence-lock.nix instead of relying on cv2.data.haarcascades.


# Low-light handling, measured 2026-10-21 on the OV2740 after dusk: frames
# sit at the noise floor (mean grey 14/255, 1st-99th percentile 9-20), where
# a single equalised frame gave 0/25 Haar hits with the user at the desk.
# Averaging the last AVG_FRAMES frames, stretching and blurring before
# equalisation raised that to 7/23. Below MIN_LUMA the picture is too dark
# to tell an empty room from a present user, so the check fails open (the
# unconditional 120s hypridle listener still locks).
AVG_FRAMES = 3
BLUR_KERNEL = (7, 7)


def mean(xs: list) -> float:
    return sum(xs) / len(xs) if xs else 0.0


def detect_faces(detector: "cv2.CascadeClassifier", frames) -> "np.ndarray":
    """Haar detection on the temporal mean of `frames`, contrast-stretched,
    blurred and equalised (see the low-light note above)."""
    avg = np.mean(np.stack(frames).astype(np.float32), axis=0)
    img = cv2.normalize(avg, None, 0, 255, cv2.NORM_MINMAX).astype(np.uint8)
    img = cv2.equalizeHist(cv2.GaussianBlur(img, BLUR_KERNEL, 0))
    return detector.detectMultiScale(img, scaleFactor=1.05, minNeighbors=4,
                                     minSize=(50, 50))


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


def stream_and_detect(detector: "cv2.CascadeClassifier", gst_launch: str,
                          target_object: str, width: int, height: int,
                          num_buffers: int, timeout: float,
                          settle_frames: int) -> tuple:
    """Streams GRAY8 frames from a gst-launch pipeline, runs Haar detection
    per frame after `settle_frames` for auto-exposure, and terminates the
    pipeline as soon as a face is found.

    Returns (face_seen, frames_seen, error, mean_luma) where mean_luma is
    the mean grey level of the post-settle frames. On any failure to start or read
    the pipeline (camera busy, missing, timed out), returns (False, n, True)
    so the caller fails open without locking. `num_buffers` is the upper
    bound on frames the pipeline will emit; the overall `timeout` caps the
    whole read."""
    frame_size = width * height
    cmd = [
        gst_launch, "-q",
        "pipewiresrc", f"target-object={target_object}", f"num-buffers={num_buffers}",
        "!", "videoconvert",
        "!", "videoscale",
        "!", f"video/x-raw,format=GRAY8,width={width},height={height}",
        "!", "fdsink", "fd=1",
    ]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError:
        log(f"gst-launch binary not found: {gst_launch}")
        return False, 0, True, 0.0
    except Exception as e:
        log(f"gst-launch failed to start: {e}")
        return False, 0, True, 0.0

    deadline = time.time() + timeout
    buf = bytearray()
    consumed = 0  # bytes already turned into frames
    frames_seen = 0
    face_seen = False
    recent: collections.deque = collections.deque(maxlen=AVG_FRAMES)
    lumas: list = []
    try:
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                log("gst-launch timed out, camera unreadable")
                return False, frames_seen, True, mean(lumas)
            # Read up to one frame's worth (or the remainder of a partial frame).
            want = frame_size - ((len(buf) - consumed) % frame_size)
            chunk = proc.stdout.read(want)
            if not chunk:
                # Pipeline closed stdout: either finished (num_buffers reached)
                # or exited. Check return code for a real error below.
                break
            buf.extend(chunk)
            while (len(buf) - consumed) >= frame_size:
                gray = np.frombuffer(
                    bytes(buf[consumed:consumed + frame_size]),
                    dtype=np.uint8,
                ).reshape(height, width)
                consumed += frame_size
                frames_seen += 1
                # Drop processed bytes to bound memory.
                if consumed > 65536:
                    del buf[:consumed]
                    consumed = 0
                # Skip the first `settle_frames` for auto-exposure to settle.
                if frames_seen <= settle_frames:
                    continue
                recent.append(gray)
                lumas.append(float(gray.mean()))
                faces = detect_faces(detector, recent)
                if len(faces) > 0:
                    face_seen = True
                    proc.terminate()
                    try:
                        proc.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
                    return True, frames_seen, False, mean(lumas)
    except Exception as e:
        log(f"error reading gst-launch: {e}")
        proc.kill()
        proc.wait()
        return False, frames_seen, True, mean(lumas)

    # Pipeline closed stdout normally (num_buffers reached) without a face.
    rc = proc.wait()
    if rc != 0:
        err = proc.stderr.read().decode(errors="replace").strip()
        log(f"gst-launch exited {rc}: {err}")
        return False, frames_seen, True, mean(lumas)
    return face_seen, frames_seen, False, mean(lumas)


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
    # 4:3: libcamera crops 640x360 from the sensor, cutting the chin
    # off a user sitting close; Haar needs the whole face.
    ap.add_argument("--height", type=int, default=480)
    ap.add_argument("--num-buffers", type=int, default=20, help="upper bound on frames to capture")
    ap.add_argument("--settle-frames", type=int, default=15,
                    help="frames to skip before running detection (auto-exposure settle)")
    ap.add_argument("--timeout", type=float, default=10.0, help="seconds to wait for gst-launch")
    ap.add_argument("--fp-grace", type=float, default=3.0,
                    help="seconds to wait for a fingerprint after a face-less check")
    ap.add_argument("--min-luma", type=float, default=30.0,
                    help="mean grey level below which the camera is too dark to judge")
    ap.add_argument("--resume-grace", type=float, default=0.5,
                    help="seconds to wait for a late on-resume marker before locking")
    ap.add_argument("--cascade", required=True, help="path to the Haar cascade XML file")
    ap.add_argument("--resumed-file",
                    default=os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/run/user/1000"),
                                         "presence-lock.resumed"),
                    help="path to the on-resume marker touched by hypridle")
    args = ap.parse_args()

    start = time.time()
    log(f"start target={args.target_object} cascade={args.cascade}")

    detector = cv2.CascadeClassifier(args.cascade)
    if detector.empty():
        log("failed to load Haar cascade")
        return 1

    # Run fprintd-verify concurrently with the face check so a finger touch
    # during the check also prevents the lock. Any failure (binary missing,
    # no enrolled finger, no reader, polkit deny, daemon down) leaves
    # fingerprint != "match", so the face result alone decides: the
    # pre-fingerprint behaviour.
    fp_proc = None
    try:
        fp_proc = subprocess.Popen(["fprintd-verify"],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except OSError as e:
        log(f"fprintd-verify unavailable, ignoring fingerprint: {e}")

    face, frames_seen, cam_error, luma = stream_and_detect(
        detector, args.gst_launch, args.target_object, args.width, args.height,
        args.num_buffers, args.timeout, args.settle_frames,
    )
    if cam_error or frames_seen == 0:
        # Camera unreadable (busy, missing, timed out): fail open, no lock.
        if fp_proc:
            fp_proc.kill()
            fp_proc.wait()
        log(f"camera unavailable (frames_seen={frames_seen}), not locking")
        return 0

    dark = not face and luma < args.min_luma
    fingerprint = "unavailable"
    if fp_proc:
        if face:
            # A face already decides; kill fprintd at once (no added latency).
            fp_proc.kill()
            fp_proc.wait()
            fingerprint = "not-needed"
        else:
            # Face check is done; give a finger touch a short grace period.
            try:
                out, _ = fp_proc.communicate(timeout=args.fp_grace)
                matched = fp_proc.returncode == 0 and b"verify-match" in out
                fingerprint = "match" if matched else "no-match"
            except subprocess.TimeoutExpired:
                fp_proc.kill()
                fp_proc.wait()
                fingerprint = "timeout"

    resumed = resumed_during_check(args.resumed_file, start)
    if face:
        decision = "skip (face)"
    elif fingerprint == "match":
        decision = "skip (fingerprint)"
    elif resumed:
        decision = "skip (resumed during check)"
    elif dark:
        decision = "skip (too dark)"
    else:
        decision = None
    log(f"face={face} frames={frames_seen} luma={luma:.1f} fingerprint={fingerprint} "
        f"resumed={resumed} decision={decision or 'lock'}")
    if decision:
        return 0

    if session_locked():
        return 0

    # Last-moment race guard: hypridle's on-resume can land just after the
    # decision (observed 150 ms later, 2026-10-21 18:02:36), so wait briefly
    # and re-check the marker right before locking.
    time.sleep(args.resume_grace)
    if resumed_during_check(args.resumed_file, start):
        log("resumed before lock, not locking")
        return 0

    try:
        subprocess.run(["loginctl", "lock-session"], timeout=5, check=False)
    except Exception as e:
        log(f"lock-session failed: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
