# v4l2loopback kernel-module config for jester.
#
# room-watch.nix feeds the shared PipeWire camera node into a v4l2loopback
# node so motion(1), which can't read PipeWire/libcamera directly, has a
# plain V4L2 device to watch. presence-lock.nix used to share this module
# too (a second node, video_nr=43), but it now grabs frames straight off
# PipeWire with a short-lived gst-launch pipeline instead of holding a
# loopback feed open, so only room-watch's node remains here.
#
# howdy.nix documents a further, currently-inactive conflict: Howdy's own
# module asserts v4l2loopback is not in boot.kernelModules at all. That is
# a separate, not-yet-resolved issue (see howdy.nix) and does not change
# anything here while howdy.nix stays unimported.
{ config, ... }:

{
  boot.extraModulePackages = [ config.boot.kernelPackages.v4l2loopback ];
  boot.kernelModules = [ "v4l2loopback" ];
  boot.extraModprobeConfig = ''
    options v4l2loopback video_nr=42 card_label=room-watch exclusive_caps=1
  '';
}
