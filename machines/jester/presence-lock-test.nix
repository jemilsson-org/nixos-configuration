{ runCommand, python3, opencv4, fetchurl }:

# YuNet model (same as presence-lock.nix)
let
  yunetModel = fetchurl {
    url = "https://media.githubusercontent.com/media/opencv/opencv_zoo/48b10fa505aeb51fbd127fc60a5c660040e823b7/models/face_detection_yunet/face_detection_yunet_2023mar.onnx";
    hash = "sha256-jyOD5N08+7RVPqhxgQf8BCMhDclk+fQoBgSATtJVL6Q=";
  };

  # Lena test image (real face for YuNet)
  lenaImage = fetchurl {
    url = "https://raw.githubusercontent.com/opencv/opencv/9171eaf2fac2382c4677f1c81e2f5fc7f9315f50/samples/data/lena.jpg";
    hash = "sha256-feftUaFZT/8kf0yuIwHs6s9TE9YBHje0pMhzP3u3LAc=";
  };
in
runCommand "presence-lock-test"
  {
    nativeBuildInputs = [ (python3.withPackages (ps: [ ps.numpy ps.opencv4 ])) ];
  }
  ''
    cp ${./presence-lock.py} presence-lock.py
    cp ${./presence-lock-test.py} presence-lock-test.py
    python3 presence-lock-test.py ${yunetModel} ${lenaImage}
    touch $out
  ''
