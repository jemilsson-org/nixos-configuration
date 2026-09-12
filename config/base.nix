{ config, lib, pkgs, ... }:
let
  nixPath = "/etc/nixPath";

  # Resource-capped wrapper for a heavy interactive build/analysis tool. Shadows
  # the real binary on PATH, then launches it nice'd + ionice'd into a transient
  # systemd --user scope so the caps bind the whole process tree as one cgroup,
  # not just the top process. base.nix stays machine-agnostic: a machine opts in
  # by setting any of <PREFIX>_MEMORY_HIGH / <PREFIX>_MEMORY_MAX / <PREFIX>_CPU_QUOTA
  # (systemd syntax, e.g. 16G, 20G, 800%). Falls back to the plain nice/ionice
  # exec when no caps are requested or there is no user systemd manager (no
  # $XDG_RUNTIME_DIR, e.g. nix build sandbox), keeping nix-built derivations
  # unaffected.
  cappedWrapper = name: envPrefix: pkgs.writeShellScriptBin name ''
    self_dir="$(cd "$(dirname "$0")" && pwd)"
    new_path=""
    IFS=:
    for d in $PATH; do
      [ "$d" = "$self_dir" ] && continue
      new_path="''${new_path:+$new_path:}$d"
    done
    unset IFS
    export PATH="$new_path"
    real_bin="$(command -v ${name})"
    if [ -z "$real_bin" ]; then
      echo "${name} wrapper: no real ${name} found on PATH" >&2
      exit 127
    fi

    limit_args=""
    [ -n "''${${envPrefix}_MEMORY_HIGH:-}" ] && limit_args="$limit_args -p MemoryHigh=${"$" + envPrefix}_MEMORY_HIGH"
    [ -n "''${${envPrefix}_MEMORY_MAX:-}" ]  && limit_args="$limit_args -p MemoryMax=${"$" + envPrefix}_MEMORY_MAX"
    [ -n "''${${envPrefix}_CPU_QUOTA:-}" ]   && limit_args="$limit_args -p CPUQuota=${"$" + envPrefix}_CPU_QUOTA"
    if [ -n "$limit_args" ] && [ -n "''${XDG_RUNTIME_DIR:-}" ] && \
       ${pkgs.systemd}/bin/systemctl --user show --property=Version >/dev/null 2>&1; then
      exec ${pkgs.systemd}/bin/systemd-run --user --scope --quiet --collect $limit_args \
        ${pkgs.coreutils}/bin/nice -n 19 ${pkgs.util-linux}/bin/ionice -c 3 "$real_bin" "$@"
    fi
    exec ${pkgs.coreutils}/bin/nice -n 19 ${pkgs.util-linux}/bin/ionice -c 3 "$real_bin" "$@"
  '';
in
{
  imports = [
    #../../hardware-configuration.nix
    ./minimum.nix
    ./default_users.nix
    ./known_hosts.nix

  ];

  networking = {
    wireguard = {
      interfaces = {
        wg0 = {
          privateKeyFile = "/var/lib/wireguard/privatekey";
          generatePrivateKeyFile = true;
        };
      };
    };
  };

  system = {
    autoUpgrade = {
      enable = true;
      flake = lib.mkDefault "github:jemilsson/nixos-configuration";
      flags = [
      ];
      dates = "Mon..Fri 02:00";
      randomizedDelaySec = "1 h";
      persistent = true;
    };

    # Configure SSH to use machine's host key for GitHub fetching
    activationScripts.setupGithubSSH = ''
      mkdir -p /root/.ssh
      cat > /root/.ssh/config <<EOF
      Host github.com
        HostName github.com
        User git
        IdentityFile /etc/ssh/ssh_host_ed25519_key
        IdentitiesOnly yes
        StrictHostKeyChecking accept-new
      EOF
      chmod 600 /root/.ssh/config
    '';

    # Display the public key for easy copying to GitHub
    activationScripts.showSSHKey = ''
      echo "================================="
      echo "Machine's SSH public key for GitHub deploy key:"
      cat /etc/ssh/ssh_host_ed25519_key.pub
      echo "================================="
    '';
  };

  systemd.tmpfiles.rules = [
    "L+ ${nixPath} - - - - ${pkgs.path}"
  ];

  boot.loader.systemd-boot.configurationLimit = 3;

  nix = {
    settings = {
      keep-derivations = false;
      keep-outputs = false;
      min-free = 1073741824;   # 1 GiB
      max-free = 3221225472;   # 3 GiB
    };
    gc = {
      automatic = true;
      options = "--delete-older-than 30d";
      dates = "Mon..Fri 03:00";
      randomizedDelaySec = "1 h";
      persistent = true;
    };
    optimise = {
      automatic = true;
      dates = [ "Mon..Fri 04:00" ];
    };

    nixPath = [ "nixpkgs=${nixPath}" ];

    daemonCPUSchedPolicy = "idle";
    daemonIOSchedClass = "idle";
  };

  systemd.timers.nixos-upgrade.timerConfig.Persistent = true;

  systemd.timers.nix-gc.after = [ "nixos-upgrade.timer" ];

  # Persistent catch-up runs fire right after boot and contend with login
  # (blame showed 3m18s / 2m12s at default priority). Idle scheduling yields
  # to foreground work while keeping the catch-up semantics; mirrors the
  # nix-daemon idle policy below. nix-optimise already inherits idle from it.
  systemd.services.nixos-upgrade.serviceConfig = {
    Nice = 19;
    IOSchedulingClass = "idle";
    CPUSchedulingPolicy = "idle";
  };
  systemd.services.nix-gc.serviceConfig = {
    Nice = 19;
    IOSchedulingClass = "idle";
    CPUSchedulingPolicy = "idle";
  };

  systemd.timers.nix-optimise.timerConfig.Persistent = true;
  systemd.timers.nix-optimise.after = [ "nixos-upgrade.timer" "nix-gc.timer" ];

  systemd.oomd.enable = true;



  security = {
    pam = {
      # pam_rssh replaces pam_ssh_agent_auth: it understands sk-ecdsa/sk-ed25519
      # FIDO keys and sends rsa-sha2-256 flags for RSA keys, which pam_ssh_agent_auth
      # 0.10.4 cannot do (last released 2019, predates FIDO SK key support).
      rssh = {
        enable = true;
        settings.auth_key_file = "/etc/ssh/authorized_keys.d/\${user}";
      };
      services.sudo.rssh = true;
      # MagicBlock ephemeral-validator requires >1M open file descriptors
      # (the exact threshold is hardcoded in the binary; 1M was insufficient,
      # bumping to 2M).
      loginLimits = [
        { domain = "*"; type = "hard"; item = "nofile"; value = "2097152"; }
        { domain = "*"; type = "soft"; item = "nofile"; value = "2097152"; }
      ];
    };
  };

  services = {
    openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = false;

        # https://blog.qualys.com/vulnerabilities-threat-research/2024/07/01/regresshion-remote-unauthenticated-code-execution-vulnerability-in-openssh-server
        LoginGraceTime = 0;
      };
    };
    journald = {
      extraConfig = ''
        MaxFileSec=1year
        SystemMaxUse=500M
      '';
    };

  };

  nixpkgs = {
    config = {
      allowUnfree = true;
      permittedInsecurePackages = [
                #"openssl-1.1.1u"
              ];
    };
  };

  programs = {
    mosh.enable = true;
    zsh = {
      ohMyZsh = {
        plugins = [
          "pass"
          "sudo"
          "systemd"
          "web-search"
          "jsontools"
          "mosh"
          "python"
          "wd"
          "per-directory-history"
          "zsh_codex"
        ];
      };
    };
  };

  #boot.extraModulePackages = [ config.boot.kernelPackages.wireguard ];

  environment = {
    #disrupts git
    #loginShellInit = "hostname | figlet -f big; fortune -a -s | cowsay";

    systemPackages = with pkgs; [
      # Interactive cargo/rustc caps via CARGO_MEMORY_HIGH/MAX + CARGO_CPU_QUOTA.
      # Note: only the env-var caps (CARGO_BUILD_JOBS etc.) reach the rustup/devenv
      # cargos that shadow this wrapper; the scope caps apply when it is invoked.
      (cappedWrapper "cargo" "CARGO")
      # CBMC model checking is single-tool but very CPU-hungry; cap via CBMC_CPU_QUOTA.
      (cappedWrapper "cbmc" "CBMC")

      #System tools
      ragenix
      htop
      git
      wget
      curl
      #unrar
      unzip
      dnsutils
      ncdu
      killall
      jq

      #Network tools
      eternal-terminal # roaming shell to the Fly devbox (`et devbox`)
      flyctl
      tcpdump
      whois
      inetutils
      traceroute

      #Neovim
      neovim
      vimPlugins.deoplete-nvim
      vimPlugins.deoplete-jedi

      #Tunneling
      wireguard-tools

      #DNS
      stubby

    ];

    shellAliases = {
      "vi" = "nvim";
      "vim" = "nvim";
      "please" = "sudo";
      "plz" = "sudo";
    };

  };

  #time.timeZone = "Europe/Stockholm";

  networking = {
    timeServers = [
      "ntp.se"
      "ntp.stupi.se"
      "ntp1.sp.se"
      "ntp2.sp.se"
      "ntp3.sp.se"
      "194.58.200.20"
      "2a01:3f7::1"
    ];
    #search = [ "jonas.systems" ];

  };


  i18n = {
    #consoleFont = "Lat2-Hack16";
    supportedLocales = [
      "en_US.UTF-8/UTF-8"
      "sv_SE.UTF-8/UTF-8"
      "en_DK.UTF-8/UTF-8" # LC_TIME, ISO 8601 date-time
      "th_TH.UTF-8/UTF-8"
    ];
  };

}

