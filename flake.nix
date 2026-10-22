{
  inputs = {
    nixpkgs = {
      url = "github:NixOS/nixpkgs/nixos-26.05";
    };
    nixpkgs-unstable = {
      url = "github:NixOS/nixpkgs/nixos-unstable";
    };
    nixpkgs-jemilsson = {
      url = "github:jemilsson-org/nixpkgs-jemilsson";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixpkgs-unstable.follows = "nixpkgs-unstable";
    };
    fafnir = {
      url = "git+ssh://git@github.com/jemilsson/fafnir";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    syna = {
      url = "git+ssh://git@github.com/jemilsson/syna";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    claude-code = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Upstream Hyprland (jester only). Deliberately NOT following nixpkgs so
    # hyprland.cachix.org binaries stay usable; overriding nixpkgs would force
    # a local rebuild of hyprland + aquamarine + hyprutils etc.
    hyprland = {
      url = "github:hyprwm/Hyprland";
    };
    nix-build-router = {
      url = "git+ssh://git@github.com/jemilsson-org/closure-build";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
      # microvm → spectrum → snix (git.snix.dev) is unreachable and unused here;
      # drop it so nixos-rebuild doesn't need to fetch it.
      inputs.microvm.inputs.spectrum.follows = "";
    };
    # bambu-studio = {
    #   url = "github:zhaofengli/nixpkgs/bambu-studio";
    # };
    #sops-nix = {
    #  url = "github:Mic92/sops-nix";
    #  inputs.nixpkgs.follows = "nixpkgs";
    #};
    /*
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix-rekey = {
      url = "github:oddlama/agenix-rekey";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    */
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, nixpkgs-jemilsson, fafnir, syna, claude-code, hyprland, nix-build-router, nixos-wsl }: # , agenix, agenix-rekey }: # bambu-studio,
    let
      system = "x86_64-linux";
      overlay-unstable = final: prev: {
        unstable = import nixpkgs-unstable {
          inherit system;
          config.allowUnfree = true;
        };
        # bambu-studio = import bambu-studio {
        #   inherit system;
        #   config.allowUnfree = true;
        # };
        th-sarabun-new = prev.callPackage ./packages/th-sarabun-new { };
        nix-tcp-proxy = prev.callPackage ./packages/nix-tcp-proxy { };
        mx-debounce = prev.callPackage ./packages/mx-debounce { };
        fafnir = fafnir.packages.${system}.default;
        syna = syna.packages.${system}.default;
        claude-code = claude-code.packages.${system}.default;
      };

      # Overlay that imports packages from nixpkgs-jemilsson
      overlay-jemilsson = final: prev: {
        jemilsson = nixpkgs-jemilsson.packages.${system};
      };

      pkgs = import nixpkgs {
        config.allowUnfree = true;
        inherit system;
        overlays = [ overlay-unstable ];
      };

      # Creates the laptop-side SSH key for the nl1 build server and prints
      # what the admin needs. Run:
      # nix run .#nl1-builder-keygen
      # See machines/jester/nl1-builder.nix.
      nl1-builder-keygen = pkgs.writeShellApplication {
        name = "nl1-builder-keygen";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          dir=/etc/nix/nl1-builder
          sudo install -d -m700 -o root -g root "$dir"
          if ! sudo test -e "$dir/ssh_ed25519"; then
            sudo ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" \
              -C "nix-daemon@jester->nl1-builder" -f "$dir/ssh_ed25519"
          fi

          echo "== SSH public key: add to the builder's nix-ssh authorized keys =="
          sudo cat "$dir/ssh_ed25519.pub"
          echo
          echo "Then, after the builder's first boot, set services.nl1-builder.keys
          in machines/jester/configuration.nix and rebuild."
        '';
      };

      # Eval-only check for machines/jester/nl1-builder.nix. With the keys null
      # the module must add nothing: nix/ssh settings equal those of jester with
      # the module disabled (what master produces). With dummy keys the builder,
      # substituter, TLS ProxyCommand and pinned host key appear. Run:
      # nix build .#checks.x86_64-linux.jester-nl1-builder-eval
      nl1Eval =
        let
          lib = nixpkgs.lib;
          dummyCache = "nl1-builder:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
          dummyHost = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDummyDummyDummyDummyDummyDummyDummyDummy";
          jester = self.nixosConfigurations.jester;
          off = (jester.extendModules { modules = [ { services.nl1-builder.keys = lib.mkForce null; } ]; }).config;
          master = (jester.extendModules {
            modules = [ { disabledModules = [ ./machines/jester/nl1-builder.nix ]; } { options.services.nl1-builder = lib.mkOption { type = lib.types.anything; default = { }; }; } ];
          }).config;
          on = (jester.extendModules {
            modules = [ { services.nl1-builder.keys = lib.mkForce { cacheKey = dummyCache; hostKey = dummyHost; }; } ];
          }).config;
          hosts = c: map (m: m.hostName) c.nix.buildMachines;
          sort = builtins.sort builtins.lessThan;
          nl1 = c: builtins.filter (m: m.hostName == "nl1-builder") c.nix.buildMachines;
          subs = c: c.nix.settings.substituters ++ (c.nix.settings.extra-substituters or [ ]);
          visible = c: {
            inherit (c.nix) distributedBuilds buildMachines extraOptions;
            settings = c.nix.settings;
            sshExtraConfig = c.programs.ssh.extraConfig;
            knownHosts = builtins.attrNames c.programs.ssh.knownHosts;
          };
          m = (builtins.head (nl1 on));
        in
        assert off.services.nl1-builder.keys == null;
        assert jester.config.services.nl1-builder.keys != null;
        assert visible off == visible master;
        assert !(builtins.elem "nl1-builder" (hosts off));
        assert on.nix.distributedBuilds;
        assert builtins.length (nl1 on) == 1;
        assert m.protocol == "ssh-ng";
        assert m.systems == [ "x86_64-linux" ];
        assert m.maxJobs == 16 && m.speedFactor == 4;
        assert m.supportedFeatures == [ "big-parallel" "benchmark" ];
        assert sort (hosts on) == sort (hosts off ++ [ "nl1-builder" ]);
        assert builtins.elem "ssh-ng://nl1-builder" (subs on);
        assert builtins.elem dummyCache on.nix.settings.extra-trusted-public-keys;
        assert on.nix.settings.builders-use-substitutes;
        assert lib.hasInfix "/bin/openssl s_client -quiet -no_ign_eof -verify_return_error" on.programs.ssh.extraConfig;
        assert lib.hasInfix "-verify_hostname builder.decentgaming.io -servername builder.decentgaming.io" on.programs.ssh.extraConfig;
        assert lib.hasInfix "-connect 175.110.121.112:443" on.programs.ssh.extraConfig;
        assert lib.hasInfix "User nix-ssh" on.programs.ssh.extraConfig;
        assert lib.hasInfix "IdentitiesOnly yes" on.programs.ssh.extraConfig;
        assert !lib.hasInfix "-cert" on.programs.ssh.extraConfig;
        assert !lib.hasInfix "-key" on.programs.ssh.extraConfig;
        assert on.programs.ssh.knownHosts.nl1-builder.publicKey == dummyHost;
        pkgs.writeText "jester-nl1-builder-eval" (builtins.toJSON {
          off = hosts off;
          on = hosts on;
          proxyCommand = lib.filter (l: lib.hasInfix "ProxyCommand" l) (lib.splitString "\n" on.programs.ssh.extraConfig);
        });
    in
    {
      overlays.default = overlay-jemilsson;

      packages.${system} = {
        mx-debounce = pkgs.callPackage ./packages/mx-debounce { };
        webcam-calibrate = pkgs.callPackage ./machines/jester/webcam-calibrate.nix { };
        inherit nl1-builder-keygen;
      };

      nixosModules = {
        serverBase = import ./config/server_base.nix;
        desktopBase = import ./config/desktop_base.nix;
        laptopBase = import ./config/laptop_base.nix;
        bareMetal = import ./config/bare_metal.nix;
        wslBase = import ./config/wsl_base.nix;
        #pkgs = pkgs;
      };
      nixosConfigurations = {
        wsl = nixpkgs.lib.nixosSystem {
          modules = [
            ({ config, pkgs, ... }: { nixpkgs.hostPlatform = system; nixpkgs.overlays = [ overlay-unstable overlay-jemilsson ]; })
            nixos-wsl.nixosModules.default
            ./machines/wsl/configuration.nix
          ];
        };

        jester = nixpkgs.lib.nixosSystem {
          specialArgs = { inherit hyprland nix-build-router; };
          modules = [
            ({ config, pkgs, ... }: { nixpkgs.hostPlatform = system; nixpkgs.overlays = [ overlay-unstable overlay-jemilsson ]; })
            fafnir.nixosModules.default
            fafnir.nixosModules.fafnir-keepassxc-bridge
            fafnir.nixosModules.fafnir-wallet
            fafnir.nixosModules.fafnir-openpgp
            fafnir.nixosModules.fafnir-pkcs11-aggregator
            syna.nixosModules.default
            ./machines/jester/configuration.nix
          ];

        };


        #lazarus = nixpkgs.lib.nixosSystem {
        #  system = "x86_64-linux";
        #  modules = [ ./machines/lazarus/configuration.nix ];
        #};
        #thor = nixpkgs.lib.nixosSystem {
        #  system = "x86_64-linux";
        #  modules = [ ./machines/thor/configuration.nix ];
        #};
      };


      apps = {
        "x86_64-linux".nl1-builder-keygen = {
          type = "app";
          program = nixpkgs.lib.getExe nl1-builder-keygen;
        };
        #"x86_64-linux" = agenix-rekey.defineApps self pkgs self.nixosConfigurations;
      };

      # Hermetic test of the shared retry body behind the `nix` / `nixos-rebuild`
      # retry wrappers (machines/jester/nix-retry.nix). shellcheck + a fake-binary
      # driver, no network/builder. Run: nix build .#checks.x86_64-linux.jester-retry-body
      checks.x86_64-linux.jester-retry-body =
        pkgs.runCommand "jester-retry-body-test"
          { nativeBuildInputs = [ pkgs.bash pkgs.shellcheck ]; } ''
          cp ${./machines/jester/retry-body.sh} retry-body.sh
          cp ${./machines/jester/retry-body.test.sh} retry-body.test.sh
          shellcheck -s bash retry-body.sh
          shellcheck -s bash -x retry-body.test.sh
          bash retry-body.test.sh
          touch $out
        '';

      # Hermetic self-test for the webcam CCM fit math (synthetic raw
      # frame, no camera/network). Run: nix build .#checks.x86_64-linux.webcam-calibrate-test
      checks.x86_64-linux.webcam-calibrate-test =
        pkgs.callPackage ./machines/jester/webcam-calibrate-test.nix { };

      # Hermetic self-test for presence-lock.py (fakes gst-launch/loginctl, no
      # real camera or session). Run: nix build .#checks.x86_64-linux.presence-lock-test
      checks.x86_64-linux.presence-lock-test =
        pkgs.callPackage ./machines/jester/presence-lock-test.nix { };

      checks.x86_64-linux.jester-nl1-builder-eval = nl1Eval;

    };
}
