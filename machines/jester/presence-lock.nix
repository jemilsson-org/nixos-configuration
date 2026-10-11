{ config, lib, pkgs, ... }:

# Presence-based early lock: touches the webcam only when about to lock, not
# 24/7. hypridle.conf's 30s listener runs presence-lock on idle; it grabs a
# handful of frames, checks for a face, and locks if none is seen -
# otherwise the existing 120s hypridle listener still locks unconditionally
# as a fallback.
#
# Camera access: the IPU6/OV2740 only enumerates via libcamera/PipeWire (see
# camera.nix), so a plain V4L2 client (cv2.VideoCapture) can't read it
# directly. A short-lived gst-launch pipeline pulls a handful of raw frames
# straight off the shared PipeWire camera node (libcamera_input.__SB_.PC00.LNK1)
# via pipewiresrc, the same node room-watch.nix's feed uses, then exits.
#
# This used to be a v4l2loopback feed service holding the camera open all
# the time (systemd.user.services.presence-lock-feed + presence-lock on a
# poll loop). libcamera is single-consumer, so that permanently blocked any
# other app (a video call, howdy, room-watch) from using the camera. On-
# demand fixes that: the pipeline only runs for the few seconds a lock
# check takes, then releases the camera. If that capture fails (camera busy
# with something else), presence-lock.py fails open and does not lock.
let
  cfg = config.services.presence-lock;

  presencePython = pkgs.python3.withPackages (ps: [ ps.opencv4 ps.numpy ]);
  gst = pkgs.gst_all_1;
  gstPluginPath = lib.makeSearchPath "lib/gstreamer-1.0" [
    gst.gstreamer.out gst.gst-plugins-base gst.gst-plugins-good pkgs.pipewire
  ];

  presenceLockScript = pkgs.writeShellApplication {
    name = "presence-lock";
    runtimeInputs = [ presencePython gst.gstreamer pkgs.systemd ];
    text = ''
      export GST_PLUGIN_SYSTEM_PATH_1_0="${gstPluginPath}"
      exec python3 ${./presence-lock.py} \
        --cascade ${pkgs.opencv4}/share/opencv4/haarcascades/haarcascade_frontalface_default.xml \
        "$@"
    '';
  };
in
{
  options.services.presence-lock = {
    enable = lib.mkEnableOption "presence-based early lock on webcam face detection" // { default = true; };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ presenceLockScript ];
  };
}
