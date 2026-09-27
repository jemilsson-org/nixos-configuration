# Shared v4l2loopback kernel-module config for jester.
#
# v4l2loopback is one kernel module instance: its options apply once, at
# first probe, for the whole module - not per video_nr. presence-lock.nix
# and room-watch.nix each used to set their own boot.extraModprobeConfig
# for this module (video_nr=43/card_label=presence-lock and
# video_nr=42/card_label=room-watch). boot.extraModprobeConfig is a single
# string option, so of those two colliding definitions only one ever won;
# in practice /dev/video42 (room-watch) came up and /dev/video43
# (presence-lock) never did, which is why presence-lock-feed.service
# restarted thousands of times (status=255, no device to open).
#
# Fix: one shared stanza naming both loopback nodes, with a matching
# comma-separated card_label list (v4l2loopback supports either a single
# card_label for all nodes or one per video_nr, in list order). Owned here,
# not inside either competing module, so a third module adding a camera
# loopback extends this list instead of adding a third colliding stanza.
# Do not split this back into per-module boot.extraModprobeConfig
# assignments: NixOS does not merge that option, so a second definition
# silently wins over the first exactly as it did before this file existed.
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
    options v4l2loopback video_nr=42,43 card_label=room-watch,presence-lock exclusive_caps=1
  '';
}
