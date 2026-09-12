{ config, lib, pkgs, ... }:
{
  imports = [
    ./minimum.nix
    ./default_users.nix
    ./known_hosts.nix
  ];

  wsl = {
    enable = true;
    defaultUser = "jonas";
    startMenuLaunchers = true;
  };

  # default_users.nix puts jonas in groups (libvirtd, docker, lxd, wireshark,
  # tss) that come from services this WSL base does not enable. Missing
  # groups only warn under plain NixOS, but nixos-wsl's minimal environment
  # errors without them defined, so define them here rather than trim the
  # shared user module.
  users.groups = {
    libvirtd = { };
    docker = { };
    lxd = { };
    wireshark = { };
    tss = { };
  };

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "jonas" ];
  };

  programs.git.enable = true;

  environment.systemPackages = with pkgs; [
    jq
    nodejs
    unstable.opencode
  ];

  time.timeZone = "Europe/Stockholm";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings.LC_TIME = "en_DK.UTF-8"; # ISO 8601 date-time

  system.stateVersion = "26.05";
}
