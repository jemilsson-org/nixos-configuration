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
    in
    {
      overlays.default = overlay-jemilsson;

      packages.${system} = {
        mx-debounce = pkgs.callPackage ./packages/mx-debounce { };
        webcam-calibrate = pkgs.callPackage ./machines/jester/webcam-calibrate.nix { };
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

    };
}
