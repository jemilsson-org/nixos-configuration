#!/usr/bin/env python3
"""Hermetic test for presence-lock.py: fakes gst-launch-1.0 and loginctl on
PATH so no real camera or session is touched. See presence-lock.nix for the
production wiring this stands in for.

Case 1: fake gst-launch prints blank (all-zero) GRAY8 frames -> no face ->
lock-session is called.
Case 2: fake gst-launch exits non-zero (camera busy, e.g. a call holds it)
-> presence-lock exits 0 and does NOT call lock-session.
"""
import os
import stat
import subprocess
import sys
import tempfile

WIDTH, HEIGHT, NUM_BUFFERS = 640, 360, 20
HERE = os.path.dirname(os.path.abspath(__file__))


def write_exe(path, contents):
    with open(path, "w") as f:
        f.write(contents)
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


def make_fakes(bindir, calls_file, gst_ok):
    # Plain /bin/sh, not a python shebang: the nix build sandbox has no
    # /usr/bin/env, so an "#!/usr/bin/env python3" shebang fails to exec
    # with a misleading "No such file or directory" pointing at the wrong
    # program.
    frame_size = WIDTH * HEIGHT
    if gst_ok:
        gst_body = f"""#!/bin/sh
{sys.executable} -c "import sys; sys.stdout.buffer.write(b'\\\\x00' * ({frame_size} * {NUM_BUFFERS}))"
"""
    else:
        gst_body = """#!/bin/sh
echo "fake gst-launch: camera busy" >&2
exit 1
"""
    write_exe(os.path.join(bindir, "gst-launch-1.0"), gst_body)

    # Records every call it receives, and answers LockedHint "no" so
    # presence-lock proceeds to check for a face / lock rather than skipping.
    loginctl_body = f"""#!/bin/sh
echo "$*" >> "{calls_file}"
case "$1 $2" in
  "show-session self") echo no ;;
esac
"""
    write_exe(os.path.join(bindir, "loginctl"), loginctl_body)


def run_case(cascade, gst_ok):
    with tempfile.TemporaryDirectory() as td:
        bindir = os.path.join(td, "bin")
        os.makedirs(bindir)
        calls_file = os.path.join(td, "calls.log")
        open(calls_file, "w").close()
        make_fakes(bindir, calls_file, gst_ok)

        env = dict(os.environ)
        env["PATH"] = bindir + ":" + env["PATH"]

        proc = subprocess.run(
            [sys.executable, os.path.join(HERE, "presence-lock.py"),
             "--cascade", cascade, "--width", str(WIDTH), "--height", str(HEIGHT),
             "--num-buffers", str(NUM_BUFFERS), "--timeout", "10"],
            env=env, capture_output=True, text=True,
        )
        calls = open(calls_file).read()
        locked = "lock-session" in calls
        return proc.returncode, locked, proc.stderr


def main():
    cascade = sys.argv[1]

    rc, locked, err = run_case(cascade, gst_ok=True)
    assert rc == 0, f"blank-frame case: expected exit 0, got {rc}: {err}"
    assert locked, f"blank-frame case: expected lock-session to be called, none logged: {err}"

    rc, locked, err = run_case(cascade, gst_ok=False)
    assert rc == 0, f"camera-busy case: expected exit 0, got {rc}: {err}"
    assert not locked, f"camera-busy case: lock-session must NOT be called when the camera is unreadable: {err}"

    print("presence-lock-test: ok")


if __name__ == "__main__":
    main()
