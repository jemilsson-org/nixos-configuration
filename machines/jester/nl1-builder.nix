{ config, lib, pkgs, ... }:

# Remote builder: guest nl1-vm4 on hypervisor nl1 (decent-nixos-configuration).
#
# Inert while `services.nl1-builder.keys` is null: nothing below is defined,
# so nix/ssh settings equal those of a config without this file. The keys
# exist only after the builder's first boot, so one nullable binding switches
# the build machine, the ssh alias and the known host on together.
#
# Path: nix-daemon (root) -> `ssh nl1-builder` -> ProxyCommand socat -> nl1:443.
# socat is a binary relay. `openssl s_client` held this slot before and
# desynchronised the byte stream under sustained concurrent load: broken pipes,
# corrupted connections and "Bad packet length" with a random length each time.
# nl1's nginx stream routes SNI builder.decentgaming.io to a TLS terminator
# that presents the public ACME cert, then forwards plain TCP to the builder's
# sshd (user nix-ssh only, nix.sshServe). The laptop never talks to nl1's own
# sshd. TLS is a proxy only; auth is SSH key only.
#
# Secrets live on the laptop only, outside the repo and the store, root-only:
#   /etc/nix/nl1-builder/ssh_ed25519   SSH key (builder authorizes its pubkey)
# Create it with `nix run .#nl1-builder-keygen`; it prints the public half.
#
# Activating (after the guest has booted once):
#   1. Builder: read the public half of its store signing key
#      ("nl1-builder:BASE64", from `nix-cache-signer --print-public-key nl1-builder`) -> `keys.cacheKey`.
#   2. Builder: read its sshd host key (/etc/ssh/ssh_host_ed25519_key.pub on
#      the guest) -> `keys.hostKey` ("ssh-ed25519 AAAA...").
#      Pinned in decent-nixos-configuration inventory.builder.hostKey: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJnEerjtjdPTVwgyXMiFdNInYIoULUlIL5qP2rZuEotF
#   3. Set `services.nl1-builder.keys` in machines/jester/configuration.nix
#      and rebuild. Check: `sudo ssh nl1-builder nix-store --version`.
let
  cfg = config.services.nl1-builder;
  dir = "/etc/nix/nl1-builder";
  alias = "nl1-builder";
  sni = "builder.decentgaming.io";
  address = "175.110.121.112"; # nl1 publicIp, decent-nixos-configuration inventory.nix
in
{
  options.services.nl1-builder.keys = lib.mkOption {
    type = lib.types.nullOr (lib.types.submodule {
      options = {
        cacheKey = lib.mkOption {
          type = lib.types.str;
          example = "nl1-builder:AAAA...=";
          description = "Public signing key of the builder's binary cache.";
        };
        hostKey = lib.mkOption {
          type = lib.types.str;
          example = "ssh-ed25519 AAAA...";
          description = "The builder sshd's host key (\"type base64\"), pinned in known_hosts.";
        };
      };
    });
    default = null;
    description = ''
      Null disables the whole module. Set to the builder's cache signing key
      and sshd host key to enable the build machine, the ssh alias and the
      pinned known host.
    '';
  };

  config = lib.mkIf (cfg.keys != null) {
    nix.buildMachines = [
      {
        hostName = alias;
        protocol = "ssh-ng";
        systems = [ "x86_64-linux" ];
        # 4, not 16: 16 concurrent copies saturated the tunnel and the builder.
        maxJobs = 4;
        speedFactor = 4;
        # No kvm or nixos-test: the guest has no nested virtualisation.
        supportedFeatures = [ "big-parallel" "benchmark" ];
      }
    ];

    nix.settings = {
      builders-use-substitutes = true;
      # No `ssh-ng://${alias}` substituter: every local build blocks on it, so a
      # flapping tunnel stalls the whole machine. HTTPS caches cover substitution;
      # nl1-builder stays a builder only.
      extra-trusted-public-keys = [ cfg.keys.cacheKey ];
    };

    # root's nix-daemon reads /etc/ssh/ssh_config. socat's verify=1 is fatal on a
    # bad chain; commonname= forces the peer name check against the SNI name
    # rather than the bare IP in the address. The CA bundle is the system one.
    programs.ssh.extraConfig = ''

      # nl1 build server, SSH inside TLS (see machines/jester/nl1-builder.nix).
      Host ${alias}
        User nix-ssh
        HostKeyAlias ${alias}
        StrictHostKeyChecking yes
        IdentitiesOnly yes
        IdentityAgent none
        IdentityFile ${dir}/ssh_ed25519
        ProxyCommand ${pkgs.socat}/bin/socat - OPENSSL:${address}:443,snihost=${sni},commonname=${sni},verify=1,cafile=${config.security.pki.caBundle}
        ServerAliveInterval 15
        ServerAliveCountMax 2
        ConnectTimeout 30
    '';

    programs.ssh.knownHosts.${alias} = {
      hostNames = [ alias ];
      publicKey = cfg.keys.hostKey;
    };
  };
}
