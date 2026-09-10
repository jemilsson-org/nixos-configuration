{ config, lib, pkgs, ... }:
{
  imports = [
    ../../config/wsl_base.nix
  ];

  networking.hostName = "wsl";
}
