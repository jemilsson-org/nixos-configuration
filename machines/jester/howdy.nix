# USB IR-camera face unlock via Howdy (fallback for the built-in IR camera,
# which is firmware-gated off on this unit; see DECISIONS.md).
#
# NOT imported by default. Two things gate turning it on:
#
# CONFLICT (must resolve first): Howdy's NixOS module asserts that
# `v4l2loopback` is NOT in `boot.kernelModules`. jester currently loads it there
# via room-watch.nix and presence-lock.nix, so importing this file as-is fails
# the build with:
#   "Adding 'v4l2loopback' to boot.kernelModules causes Howdy to no longer work."
# Resolve by removing "v4l2loopback" from `boot.kernelModules` in room-watch.nix
# (keep it in `boot.extraModulePackages`) and load it on demand instead, e.g. a
# oneshot `systemd.services.room-watch` ExecStartPre `modprobe v4l2loopback`,
# or gate room-watch and howdy so they are not both active. Verified: with the
# loopback in kernelModules the toplevel build aborts on that assertion.
#
# When you have a USB Windows-Hello IR camera:
#   1. Plug it in, find its IR video node:
#        v4l2-ctl --list-devices          # identify the camera
#        for d in /dev/video*; do echo "$d:"; v4l2-ctl -d $d --all 2>/dev/null \
#          | grep -iE "Pixel Format|Name"; done
#      The IR sensor is the node reporting a GREY/Y8 (mono) format, not YUYV/MJPG.
#   2. Set device_path below to that node.
#   3. Add `./howdy.nix` to imports in configuration.nix, rebuild.
#   4. Enroll your face:  sudo howdy add
#   5. Test:  sudo -k; sudo true   (should unlock by face, fall back to password)
#
# Security note (from the module itself): Howdy can be fooled by a printed photo.
# It is configured "sufficient" (an ADDITIONAL factor); password always still works.
# Do not make it the sole auth method.
{ lib, config, ... }:
{
  services.howdy = {
    enable = true;
    # PAM control: "sufficient" = face OR password (recommended). Password prompt
    # still appears as fallback. Use the default; do not set "required".
    settings = {
      core = {
        # Lower = stricter match (fewer false accepts). 3.5 is the module default;
        # tune after enrollment with `sudo howdy test`.
        certainty = 3.5;
        # Show the password prompt immediately alongside the face scan so a failed
        # or slow scan never blocks you.
        no_confirmation = true;
        abort_if_ssh = true;
        abort_if_lid_closed = true;
      };
      video = {
        # TODO: set to your USB IR camera's MONO (GREY/Y8) node, e.g. /dev/video4.
        # Left as a clearly-wrong placeholder so a mis-config fails loudly rather
        # than silently grabbing the RGB webcam.
        device_path = "/dev/video-SET-ME-to-usb-ir-node";
        device_format = "v4l2";
        # Many USB Hello cameras ship the IR frame dark until the IR emitter is
        # kicked; if your face scan sees only black, enable the emitter (below)
        # and/or raise dark_threshold.
        dark_threshold = 90;
        # A USB IR sensor needs no rotation normally; adjust if enrollment is sideways.
        rotate = 0;
      };
    };
  };

  # Present Howdy to the auth flows you actually use. The howdy module wires the
  # PAM stack when enabled; this just makes the intent explicit and covers sudo,
  # login, and the Hyprland lock (swaylock uses its own PAM service "swaylock").
  security.pam.services = lib.mkIf config.services.howdy.enable {
    sudo.rules.auth.howdy.order = lib.mkDefault 11400;
    login.rules.auth.howdy.order = lib.mkDefault 11400;
  };

  # Many off-the-shelf Windows-Hello USB cameras need the IR emitter triggered
  # before each capture. If your camera's IR frame is black, enable this and run
  # `sudo linux-enable-ir-emitter configure` to record the trigger for your model.
  # services.linux-enable-ir-emitter.enable = true;
}
