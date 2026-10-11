#!/usr/bin/env python3
"""Presence-based auto-lock: one-shot check, run on-demand by a hypridle
listener (see hypr/hypridle.conf), not a long-running daemon.

Touches the webcam only for the few seconds this check needs, then lets it
go: libcamera is single-consumer, so a permanently-open feed (the old
presence-lock-feed.service) blocked every other app from the camera. This
spawns a short gst-launch pipeline that pulls a handful of raw frames
straight off the shared PipeWire camera node, runs face detection on the
last few (letting auto-exposure settle), and only then decides whether to
lock. No frames, an unreadable camera, or a timeout (e.g. a video call
already holds the camera) all fail open: log and exit without locking. See
presence-lock.nix for the packaging and why libcamera forces this route
instead of a plain cv2.VideoCapture.
"""
import argparse
import subprocess
import sys

import cv2
import numpy as np

# nixpkgs' opencv4 python bindings don't ship cv2.data (no bundled cascade
# dir), unlike upstream pip wheels, so the cascade path is passed in
# explicitly by presence-lock.nix instead of relying on cv2.data.haarcascades.


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
        print(f"presence-lock: loginctl check failed, skipping: {e}", file=sys.stderr)
        return True


def grab_frames(gst_launch: str, target_object: str, width: int, height: int,
                 num_buffers: int, timeout: float) -> list:
    """Runs a short gst-launch pipeline and returns the raw GRAY8 frames it
    produced, or [] on any error/timeout (camera busy, missing, etc.)."""
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
        proc = subprocess.run(cmd, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        print("presence-lock: gst-launch timed out, camera unreadable", file=sys.stderr)
        return []
    if proc.returncode != 0:
        print(
            f"presence-lock: gst-launch exited {proc.returncode}: "
            f"{proc.stderr.decode(errors='replace').strip()}",
            file=sys.stderr,
        )
        return []
    data = proc.stdout
    frames = [
        np.frombuffer(data[i:i + frame_size], dtype=np.uint8).reshape(height, width)
        for i in range(0, len(data) - frame_size + 1, frame_size)
    ]
    return frames


def any_face(detector: "cv2.CascadeClassifier", frames: list) -> bool:
    """Runs Haar detection on the last few frames (auto-exposure needs a
    handful of frames to settle) and returns True if any shows a face."""
    # Params tuned live against real images (a portrait with a face, a
    # camera frame of an empty room): equalizeHist + scaleFactor=1.05,
    # minNeighbors=4, minSize=50 cleanly separated the two (1 face vs. 0);
    # scaleFactor 1.1+ missed the real face, minNeighbors 3 / minSize 40
    # false-positived on the empty room.
    for gray in frames[-5:]:
        gray = cv2.equalizeHist(gray)
        faces = detector.detectMultiScale(gray, scaleFactor=1.05, minNeighbors=4, minSize=(50, 50))
        if len(faces) > 0:
            return True
    return False


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--gst-launch", default="gst-launch-1.0", help="gst-launch-1.0 binary")
    ap.add_argument("--target-object", default="libcamera_input.__SB_.PC00.LNK1",
                     help="PipeWire camera node name")
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--height", type=int, default=360)
    ap.add_argument("--num-buffers", type=int, default=20, help="frames to capture")
    ap.add_argument("--timeout", type=float, default=10.0, help="seconds to wait for gst-launch")
    ap.add_argument("--cascade", required=True, help="path to the Haar cascade XML file")
    args = ap.parse_args()

    detector = cv2.CascadeClassifier(args.cascade)
    if detector.empty():
        print("presence-lock: failed to load Haar cascade", file=sys.stderr)
        return 1

    frames = grab_frames(
        args.gst_launch, args.target_object, args.width, args.height,
        args.num_buffers, args.timeout,
    )
    if not frames:
        # Camera unreadable (busy, missing, timed out): fail open, no lock.
        print("presence-lock: no frames captured, camera unavailable, not locking", file=sys.stderr)
        return 0

    if any_face(detector, frames):
        return 0

    if session_locked():
        return 0

    print("presence-lock: no face seen, locking", file=sys.stderr)
    try:
        subprocess.run(["loginctl", "lock-session"], timeout=5, check=False)
    except Exception as e:
        print(f"presence-lock: lock-session failed: {e}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
