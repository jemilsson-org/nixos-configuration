{ config, lib, pkgs, ... }:

# Presence-based auto-lock: locks the Hyprland session when the RGB webcam
# sees no face for --timeout seconds. Unlock stays on the existing hyprlock
# setup (config/i3_x11.nix) - out of scope here.
#
# Camera access: the IPU6/OV2740 only enumerates via libcamera/PipeWire (see
# camera.nix), so a plain V4L2 client (cv2.VideoCapture) can't read it
# directly. Reuses the same feeder pattern as room-watch.nix - a gstreamer
# pipewiresrc pulls the shared pipewire camera node
# (libcamera_input.__SB_.PC00.LNK1) into a dedicated v4l2loopback device.
# This was chosen over (a) opening libcamerasrc directly, which contends
# with wireplumber for exclusive device access, and (b) unverified: pipewire
# fan-out to a second low-rate consumer via pipewiresrc is exactly what (c)
# already does today in room-watch-feed.service, proven live on this machine
# (started, produced real YUY2 frames on /dev/video42, read back with
# ffmpeg) with wireplumber's own camera consumers unaffected.
#
# Runs on its own loopback device/module instance so it never collides with
# room-watch's video42 when both happen to be enabled.

let
  cfg = config.services.presence-lock;
  gst = pkgs.gst_all_1;
  loopbackDev = "/dev/video43";

  presencePython = pkgs.python3.withPackages (ps: [ ps.opencv4 ]);

  presenceLockScript = pkgs.writeShellApplication {
    name = "presence-lock";
    runtimeInputs = [ presencePython pkgs.util-linux ];
    text = ''
      exec python3 ${./presence-lock.py} \
        --device ${loopbackDev} \
        --interval ${toString cfg.interval} \
        --timeout ${toString cfg.timeout} \
        --cascade ${pkgs.opencv4}/share/opencv4/haarcascades/haarcascade_frontalface_default.xml \
        "$@"
    '';
  };
in
{
  options.services.presence-lock = {
    enable = lib.mkEnableOption "presence-based auto-lock on webcam face detection" // { default = true; };
    interval = lib.mkOption {
      type = lib.types.numbers.positive;
      default = 3;
      description = "Seconds between camera polls.";
    };
    timeout = lib.mkOption {
      type = lib.types.numbers.positive;
      default = 45;
      description = "Seconds with no face detected before locking the session.";
    };
  };

  config = lib.mkIf cfg.enable {
    # v4l2loopback kernel-module config (video_nr=43, card_label=presence-lock)
    # lives in ./v4l2loopback.nix, shared with room-watch.nix: the module is a
    # single instance and its options can't be split across two stanzas.

    systemd.user.services.presence-lock-feed = {
      description = "PipeWire camera feed into v4l2loopback for presence-lock";
      requires = [ "pipewire.service" ];
      after = [ "pipewire.service" "wireplumber.service" ];
      partOf = [ "presence-lock.service" ];
      serviceConfig = {
        # Low framerate: this only needs ~1 frame per poll interval, not a
        # smooth video stream, so keep it cheap on CPU/power.
        ExecStart = ''
          ${gst.gstreamer}/bin/gst-launch-1.0 -e \
            pipewiresrc target-object=libcamera_input.__SB_.PC00.LNK1 \
            ! videoconvert ! video/x-raw,format=YUY2,width=640,height=360,framerate=5/1 \
            ! v4l2sink device=${loopbackDev} sync=false
        '';
        Restart = "on-failure";
        RestartSec = 5;
      };
      environment.GST_PLUGIN_SYSTEM_PATH_1_0 = lib.makeSearchPath "lib/gstreamer-1.0" [
        gst.gstreamer.out gst.gst-plugins-base gst.gst-plugins-good pkgs.pipewire
      ];
    };

    systemd.user.services.presence-lock = {
      description = "Lock the session when no face is seen by the webcam";
      requires = [ "presence-lock-feed.service" ];
      after = [ "presence-lock-feed.service" "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = "${presenceLockScript}/bin/presence-lock";
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };
  };
}
