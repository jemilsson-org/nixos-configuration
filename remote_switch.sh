#!/bin/sh
# Evaluate and build this host's system on the builder, then switch to it.
# Unlike `nixos-rebuild --build-host`, evaluation also runs remotely.
# Needs a shell account on $BUILDER_HOST; the nix-ssh store user is not enough.
# The flake ref must be fetchable by the builder (no uncommitted local changes).
set -eu
BUILDER_HOST="${BUILDER_HOST:-nl1-eval}"
FLAKE="${FLAKE:-github:jemilsson/nixos-configuration}"
HOST="${1:-$(hostname)}"

path=$(ssh "$BUILDER_HOST" nix build --no-link --print-out-paths \
  "'$FLAKE#nixosConfigurations.\"$HOST\".config.system.build.toplevel'")
# nix copy uses the store user (nix-ssh) over ssh-ng, not the shell user.
nix copy --from "ssh-ng://nl1-builder" "$path"
sudo nixos-rebuild switch --store-path "$path"
