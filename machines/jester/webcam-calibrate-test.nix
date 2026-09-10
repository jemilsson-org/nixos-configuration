# Hermetic self-test for webcam-calibrate.py's fit_ccm() math: synthesises
# a raw SGRBG10 frame under a known CCM and checks the recovered matrix.
# See webcam-calibrate-test.py's module docstring.
{ runCommand, python3 }:

runCommand "webcam-calibrate-test"
  {
    nativeBuildInputs = [ (python3.withPackages (ps: [ ps.numpy ps.opencv4 ])) ];
  }
  ''
    cp ${./webcam-calibrate.py} webcam-calibrate.py
    cp ${./webcam-calibrate-test.py} webcam-calibrate-test.py
    python3 webcam-calibrate-test.py
    touch $out
  ''
