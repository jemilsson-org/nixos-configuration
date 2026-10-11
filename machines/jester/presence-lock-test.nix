# Hermetic self-test for presence-lock.py's face-check / fail-open logic:
# fakes gst-launch-1.0 and loginctl on PATH, feeds synthetic blank frames
# through the real detector, and checks lock-session is (and is not) called
# in the right cases. See presence-lock-test.py's module docstring.
{ runCommand, python3, opencv4 }:

runCommand "presence-lock-test"
  {
    nativeBuildInputs = [ (python3.withPackages (ps: [ ps.numpy ps.opencv4 ])) ];
  }
  ''
    cp ${./presence-lock.py} presence-lock.py
    cp ${./presence-lock-test.py} presence-lock-test.py
    python3 presence-lock-test.py ${opencv4}/share/opencv4/haarcascades/haarcascade_frontalface_default.xml
    touch $out
  ''
