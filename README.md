# My nixos configuration

```
#!/bin/sh
sudo rm -r /etc/nixos/nixos-configuration/
sudo rm /etc/nixos/configuration.nix
cd /etc/nixos
sudo git clone https://github.com/jemilsson/nixos-configuration.git
#set -x HOSTNAME (hostname -f)
sudo ln -sr /etc/nixos/nixos-configuration/machines/$HOSTNAME/configuration.nix  configuration.nix
sudo nix-channel --add https://nixos.org/channels/nixos-unstable nixos-unstable
sudo nix-channel --add https://nixos.org/channels/nixos-20.03 nixos
sudo nix-channel --update
sudo nixos-rebuild switch --upgrade

```

## Using flakes

```
sudo nixos-rebuild switch --upgrade --flake github:jemilsson/nixos-configuration

sudo nixos-rebuild switch --upgrade --flake '.#'


nix flake update
```

## WSL

The `wsl` host runs NixOS-WSL on a Windows machine.

Install:

1. Download `nixos.wsl` from https://github.com/nix-community/NixOS-WSL/releases/latest and double-click it, or run `wsl --install --from-file nixos.wsl`.
2. Open the new distro (`wsl -d NixOS`) and run:

```sh
sudo nixos-rebuild switch --flake github:jemilsson/nixos-configuration#wsl
```

3. Exit and run `wsl -t NixOS` once so the default user switches to `jonas`.

Other flakes can reuse the base module:

```nix
modules = [
  nixos-wsl.nixosModules.default
  nixos-configuration.nixosModules.wslBase
];
```
