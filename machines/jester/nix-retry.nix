# Transparent retry wrappers for `nix` (build / flake check) and `nixos-rebuild`
# (switch / boot / test / build / ...).
#
# jester offloads ALL builds to a remote builder (closure.build's Fly.io
# gateway; previously also somchai, an AWS spot builder on a Stockholm<->
# Bangkok link). The long-haul ssh-ng mux drops mid-build and nix has NO
# built-in retry, so two transient failure classes crash builds outright:
#   1. Mid-build mux drop: a TCP drop on the persistent master EPIPEs every
#      multiplexed channel at once ("error: writing to file: Broken pipe" /
#      "Nix daemon disconnected unexpectedly" was the single most common crash
#      across 12k+ build invocations; also Connection reset/closed/timed out,
#      ssh_exchange_identification).
#   2. Cold-start race: the first SSH to a just-provisioned remote builder
#      fails, nix drops it from the builder set, then "failed to start SSH
#      connection" -> "Failed to find a machine for remote build" -> "Unable
#      to start any build". A re-run succeeds once the builder is up.
# jonas's ~/.config/nix sets max-jobs=0 (force-offload), so when the only builder
# is ejected there is NO local fallback and the build hard-fails. The wrappers
# retry ONLY the transient signatures (shared allowlist in retry-body.sh) and
# fail fast on genuine build errors. Build inputs are cached, so a retry is cheap.
#
# TWO wrappers are required, not one:
#   - `nix build` / `nix flake check` (jonas's interactive builds) -> `nix` wrapper.
#   - `nixos-rebuild switch` (system deploys) runs nixos-rebuild-ng, which
#     PREPENDS its OWN bundled nix to PATH and invokes ["nix","build"] via PATH
#     lookup, BYPASSING the `nix` wrapper. So system rebuilds are only protected
#     by also wrapping `nixos-rebuild`. (nixos-rebuild's internal re-exec uses
#     absolute store paths via os.execve, never a PATH lookup, so the wrapper is
#     not re-entered -- no recursion.)
#
# KNOWN RESIDUALS (retry is a mitigation, not a cure for the flaky WAN):
#   - A SINGLE derivation that consistently takes longer than the mux survives
#     cannot be rescued: nix has no intra-derivation resume, so every retry
#     rebuilds that .drv from scratch and races the same link. Retry fixes drops
#     that land between derivations, on the cold-box wake, or in builds short
#     enough to fit a window. The real fix for the long tail is link
#     survivability (reconnecting mux) or opt-in local fallback (jonas's
#     max-jobs=0 deliberately has none).
#   - `nix develop` / `nix shell` / `nix run` are NOT retried: their build phase
#     can't be separated from the interactive subshell exec without breaking the
#     loop's stdout/stderr capture. Re-run by hand if a devShell build drops.
{ config, lib, pkgs, ... }:
let
  # writeShellScriptBin produces a plain bash script (no `set -e`), which is what
  # retry-body.sh's explicit exit-code handling needs. The PATH prefix gives the
  # body its own tools (tail/grep/mktemp/sleep) and is inherited by `$real`;
  # coreutils-full matches the system default so nothing the wrapped tool needs
  # is shadowed by the minimal coreutils.
  mkRetry = { name, real, kind }:
    pkgs.writeShellScriptBin name ''
      export PATH=${lib.makeBinPath [ pkgs.coreutils-full pkgs.gnugrep ]}''${PATH:+:$PATH}
      real=${real}
      RETRY_KIND=${kind}
      source ${./retry-body.sh}
    '';

  nixRetry = mkRetry {
    name = "nix";
    real = "${config.nix.package}/bin/nix";
    kind = "nix";
  };

  nixosRebuildRetry = mkRetry {
    name = "nixos-rebuild";
    real = "${config.system.build.nixos-rebuild}/bin/nixos-rebuild";
    kind = "nixos-rebuild";
  };
in
{
  # hiPrio wins the systemPackages collision against config.nix.package (`nix`)
  # and the nixos-rebuild module (`nixos-rebuild`) so the wrappers land first in
  # /run/current-system/sw/bin. There is only ONE `nix` / `nixos-rebuild` in the
  # profile, so any PATH that resolves them resolves the wrapper -- including
  # `sudo nixos-rebuild`, whose PATH must contain the profile bin dir anyway.
  # The wrappers exec the real binaries by absolute store path, so the
  # nix-daemon (which uses config.nix.package directly) is unaffected.
  environment.systemPackages = [
    (lib.hiPrio nixRetry)
    (lib.hiPrio nixosRebuildRetry)
  ];
}
