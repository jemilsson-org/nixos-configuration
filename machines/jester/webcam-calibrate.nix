{ writers, writeShellApplication, python3Packages, libcamera }:

let
  # numpy + opencv4 (nixpkgs' opencv4 is built with contrib, giving
  # cv2.mcc for ColorChecker auto-detection -- see webcam-calibrate.py).
  calibratePy = writers.writePython3Bin "webcam-calibrate-py"
    {
      libraries = [ python3Packages.numpy python3Packages.opencv4 ];
      # The reference-value table and the rationale comment block in the
      # module docstring read better unwrapped than hard-split at 79 cols.
      flakeIgnore = [ "E501" ];
    }
    (builtins.readFile ./webcam-calibrate.py);
in
writeShellApplication {
  name = "webcam-calibrate";
  runtimeInputs = [ calibratePy libcamera ];
  text = ''
    exec webcam-calibrate-py "$@"
  '';
  meta.description = "Colour-correction-matrix calibration for jester's OV2740 webcam";
}
