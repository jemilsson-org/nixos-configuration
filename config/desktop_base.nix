{ config, lib, pkgs, ... }:
let
  vscode-claude-code = pkgs.unstable.vscode-extensions.anthropic.claude-code;
  vscode-3d-preview = pkgs.jemilsson.vscode-3d-preview;
  quarto = pkgs.jemilsson.quarto;
  djlint = pkgs.jemilsson.djlint;
  cloudformation-yaml-validator = pkgs.jemilsson.cloudformation-yaml-validator;
  boto3-ide = pkgs.jemilsson.boto3-ide;
  tratex-font = pkgs.jemilsson.tratex-font;

  # mkVideoMaskedWrapper — bubblewrap shell wrapper that masks only the /dev/video*
  # nodes. The Intel IPU6 ISYS exposes 32 raw V4L2 capture nodes that hang on
  # VIDIOC_QUERYCAP; Electron/Chromium's V4L2 device factory probes them and
  # stalls navigator.mediaDevices.enumerateDevices() forever, which breaks the
  # microphone AND camera in web apps. There is no flag to skip the V4L2 factory,
  # so we neutralise the nodes: each /dev/video* is overmounted with /dev/null, so
  # the QUERYCAP ioctl returns ENOTTY instantly instead of hanging. The webcam
  # still works when --enable-features=WebRtcPipeWireCamera is active (baked into
  # chromiumBase commandLineArgs; passed as a preArg for other Electron apps),
  # which pulls the camera over the PipeWire camera portal, needing no /dev/video.
  #
  # The rest of /dev is the host's real /dev (--dev-bind /dev /dev), NOT a fresh
  # minimal one. An earlier version used `--dev /dev`, but that hid every other
  # device node too - notably /dev/hidraw*, silently breaking WebAuthn/FIDO2
  # security keys (physical YubiKeys and the fafnir TPM-backed virtual key). It
  # also created a launch-order trap: nodes appearing after launch (hidraw hotplug,
  # a fafnir-passkey restart) never showed up in the frozen sandbox. Binding the
  # real /dev makes all device nodes live, matching the nixpkgs default chromium's
  # device exposure (no security regression; the bwrap layer exists solely for the
  # V4L2 workaround). Verified: enumerateDevices returns ~50ms, getUserMedia video
  # yields "Built-in Front Camera", and /dev/hidraw* (incl. a fafnir key started
  # after Chromium) are visible.
  mkVideoMaskedWrapper = { name, exe, preArgs ? [] }:
    let
      preArgsStr = builtins.concatStringsSep " " preArgs;
    in
    lib.hiPrio (pkgs.writeShellScriptBin name ''
      # The Hyprland security wrapper raises CAP_SYS_NICE into the ambient set so
      # the compositor can use realtime scheduling; ambient caps inherit into every
      # descendant, so this script inherits it too. bwrap refuses to start when it
      # holds capabilities while not setuid ("Unexpected capabilities but not
      # setuid"), which silently breaks the app. Drop ambient caps before exec.
      #
      # Mask each present /dev/video* with /dev/null (see mkVideoMaskedWrapper comment).
      # Built dynamically so it adapts to however many ISYS nodes exist at launch.
      videomask=()
      for v in /dev/video*; do
        [ -e "$v" ] && videomask+=(--bind /dev/null "$v")
      done
      exec ${pkgs.util-linux}/bin/setpriv --ambient-caps -all -- \
        ${pkgs.bubblewrap}/bin/bwrap \
        --bind / / \
        --dev-bind /dev /dev \
        "''${videomask[@]}" \
        ${exe} ${preArgsStr} "$@"
    '');
  chromiumBase = pkgs.chromium.override {
    commandLineArgs = [
      "--remote-debugging-port=9222"
      "--remote-debugging-address=127.0.0.1"
      "--remote-allow-origins=http://127.0.0.1:9222"
      "--disk-cache-size=536870912"
      # One combined --enable-features (a later occurrence would override an
      # earlier one). WebRtcPipeWireCamera is load-bearing for mic+camera (see
      # bwrap comment above; previously set via CHROMIUM_FLAGS, which the inner
      # nixpkgs wrapper never reads - it was applying only by chromium's own
      # default). Vaapi* enables hardware video decode on the iHD driver
      # (LIBVA_DRIVER_NAME below): ~15-25% of a P-core saved during video
      # playback/calls. VaapiIgnoreDriverChecks deliberately omitted while xe
      # GuC stalls are live; verify chrome://gpu shows "Video Decode: Hardware
      # accelerated" and watch journalctl -k for new xe resets after deploy.
      "--enable-features=WebRtcPipeWireCamera,VaapiVideoDecodeLinuxGL,VaapiVideoDecoder"
      "--font-render-hinting=none"
      "--force-dark-mode"
    ];
  };
  chromiumSandboxed = mkVideoMaskedWrapper {
    name = "chromium";
    exe = "${chromiumBase}/bin/chromium";
    # No preArgs: WebRtcPipeWireCamera is baked into chromiumBase commandLineArgs.
  };
  signalSandboxed = mkVideoMaskedWrapper {
    name = "signal-desktop";
    exe = "${pkgs.signal-desktop}/bin/signal-desktop";
    preArgs = [ "--enable-features=WebRtcPipeWireCamera" ];
  };

  vscode-extensions = (with pkgs.unstable.vscode-extensions; [
    vscode-claude-code

    #Python support
    ms-python.python

    antyos.openscad
    vscode-3d-preview

    #General tools
    # continue.continue commenting it because it's too old in nixpkgs
    rooveterinaryinc.roo-cline
    continue.continue
    eamodio.gitlens

    #Data formats
    yzhang.markdown-all-in-one

    #Themes
    github.github-vscode-theme

    quarto

    #Glecom vscode recommendations
    editorconfig.editorconfig
    tamasfe.even-better-toml
    charliermarsh.ruff
    redhat.vscode-yaml
    jnoortheen.nix-ide
    github.vscode-github-actions
    timonwong.shellcheck
    foxundermoon.shell-format
    davidanson.vscode-markdownlint
    djlint
    astro-build.astro-vscode
    cloudformation-yaml-validator
    bradlc.vscode-tailwindcss
    boto3-ide
    ms-python.vscode-pylance
    esbenp.prettier-vscode
    mkhl.direnv
  ]);
  my-vscode-with-extensions = pkgs.unstable.vscode-with-extensions.override {
    vscodeExtensions = vscode-extensions;
  };

in
{
  imports = [
    ./base.nix
    ./wallpapers.nix
    ./bare_metal.nix
    ./bedrock-access-gateway.nix
    ./appearance.nix
    #./systemd_user/gpg-agent.nix
    # fafnir service is configured via services.fafnir in each machine's configuration.nix
    ./systemd_user/claude-log-cleanup.nix
    #./x11.nix

  ];


  xdg =
    {
      portal = {
        enable = true;
        # Screen sharing on Hyprland is provided by xdg-desktop-portal-hyprland.
        # wlr.enable is intentionally NOT set: the wlr ScreenCast backend would
        # compete with the hyprland one and break the screen-share picker.
        # Interface routing lives in appearance.nix (xdg.portal.config.common).
      };
    };

  boot = {
    extraModulePackages = with config.boot.kernelPackages;
      [  ];
    kernelParams = [ "rw" ];
  };


  # GTK icon cache moved to appearance.nix

  security.rtkit.enable = true;

  hardware = {
    enableAllFirmware = true;

    bluetooth = {
      enable = true;
      powerOnBoot = true;
      #package = pkgs.bluezFull;
      settings = {
        General = {
          #Experimental = true;
        };
      };
    };

    rtl-sdr.enable = true;

    graphics = {
      enable = true;
      enable32Bit = true;
      extraPackages = with pkgs; [
        intel-compute-runtime
        intel-media-driver
        libvdpau-va-gl
        libva-vdpau-driver
        intel-vaapi-driver
        vpl-gpu-rt
      ];
      extraPackages32 = with pkgs; [
        intel-compute-runtime
        intel-media-driver
        libvdpau-va-gl
        libva-vdpau-driver
        intel-vaapi-driver
        vpl-gpu-rt
      ];
    };

    steam-hardware = {
      enable = true;
    };

    ledger = {
      enable = true;
    };

    logitech = {
      wireless = {
        enable = true;
        enableGraphical = true;
      };
    };

    flipperzero.enable=true;

  };

  networking.networkmanager.enable = true;

  xdg.mime.defaultApplications = {
    "text/html" = "chromium-browser.desktop";
    "x-scheme-handler/http" = "chromium-browser.desktop";
    "x-scheme-handler/https" = "chromium-browser.desktop";
    "x-scheme-handler/about" = "chromium-browser.desktop";
    "x-scheme-handler/unknown" = "chromium-browser.desktop";
  };
  environment.sessionVariables.BROWSER = "chromium";
  environment.sessionVariables.DEFAULT_BROWSER = "chromium";
  networking.networkmanager.settings.connectivity = {
    uri = "http://connectivitycheck.grapheneos.network/generate_204";
    interval = "300";
    response = "";
  };

  # Makes the nixpkgs chromium/electron wrappers emit --ozone-platform-hint=auto
  # (Wayland when available, X11 fallback otherwise). Chromium already ran
  # Wayland via auto-detection; this makes it explicit in the hint form.
  environment.sessionVariables.NIXOS_OZONE_WL = "1";
  # Intel media driver for VA-API hardware video decode (Iris Xe); reaches
  # chromium because the bwrap wrapper preserves the environment and
  # /run/opengl-driver is bind-mounted.
  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";


  environment.systemPackages = with pkgs; [
    android-tools
    ghostscript

    #Browsers
    firefox
    chromiumBase        # provides .desktop entry, icons, mime; bin/chromium is
    chromiumSandboxed   # shadowed by this bwrap wrapper (lib.hiPrio) so the
                        # desktop launcher (Exec=chromium) and CLI both sandbox.
    google-chrome
    #unstable-small.tor-browser-bundle-bin

    #Media
    (pkgs.symlinkJoin {  # GPU sandbox fails on kernel 7.1 (zygote ping lost, GPU process unusable)
      name = "spotify";
      paths = [ pkgs.spotify ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = "wrapProgram $out/bin/spotify --add-flags --disable-gpu-sandbox";
    })
    vlc
    mplayer
    smplayer
    pavucontrol
    pasystray
    audacity
    gimp
    exiftool
    playerctl
    deluge

    #3D design
    openscad
    #unstable.bambu-studio
    #cura
    meshlab


    ffmpeg-full
    #v4l-utils
    imagemagick

    #Programming
    #atom
    (python3.withPackages (ps: with ps; [
      yapf
      flake8
      autopep8
      uvicorn
      numpy
      pillow
      pylint
      scipy
      matplotlib
      pymeeus
      jupyter
      plotly
      markitdown
      copier
    ]))
    my-vscode-with-extensions
    #insomnia
    bruno
    vscodium
    emacs
    #aws-sam-cli

    ## Nix

    nixpkgs-fmt
    nil
    nixd

    ## Pony
    #ponyc
    #pony-corral


    #Interface
    alacritty
    foot
    kitty
    #albert  # Temporarily disabled due to submodule authentication issues
    synapse
    feh
    (freerdp.override { pcsclite = pcsclite; libpulseaudio = libpulseaudio; })
    rdesktop
    appimage-run

    #Ricing packages moved to appearance.nix

    #Graphical System tools
    gedit
    nautilus
    sushi
    file-roller
    gparted
    file
    keepass
    libreoffice
    mupdf
    quarto
    #adobe-reader

    #Communication
    pidgin
    signal-desktop      # provides .desktop entry, icons, mime; bin/signal-desktop
    signalSandboxed     # shadowed by this bwrap wrapper (lib.hiPrio) — same
                        # V4L2/PipeWire treatment as chromiumSandboxed.
    teams-for-linux
    discord
    #skype

    #(steam.override { extraPkgs = pkgs: with pkgs.pkgsi686Linux; [ libva ]; })

    #Games
    #unstable-small.steam
    #(unstable.steam.override {  extraPkgs = pkgs: with pkgs.pkgsi686Linux; [ alsaLib alsaPlugins libpulseaudio ]; })
    #(unstable.winetricks.override { wine = unstable.wine.override { wineBuild = "wineWow"; };} )
    #(unstable.wine.override { wineBuild = "wineWow"; })
    #polymc
    #minecraft
    virtualgl

    #Security
    libu2f-host
    yubikey-personalization
    yubico-piv-tool
    pcsc-tools
    opensc
    yubikey-manager
    openssl
    libp11
    #scd-pkcs11
    #kdeApplications.kleopatra

    pass
    # gpg-agent sometimes loses the YubiKey card-key mapping ("decryption
    # failed: No secret key" with the card present); re-LEARN and retry once.
    (lib.hiPrio (writeShellScriptBin "pass" ''
      err=$(mktemp)
      trap 'rm -f "$err"' EXIT
      # tee stderr (not buffer) so interactive prompts stay visible
      { ${pass}/bin/pass "$@" 2>&1 1>&3 | tee "$err" >&2; } 3>&1
      rc=''${PIPESTATUS[0]}
      if [ "$rc" -ne 0 ] && grep -q 'No secret key' "$err"; then
        # retry only non-mutating commands: a replay of insert/edit/generate/...
        # could re-run with drained stdin or partially applied state
        case "''${1-}" in
          init|insert|edit|generate|rm|mv|cp|git) ;;
          *)
            ${gnupg}/bin/gpg-connect-agent 'scd serialno' 'learn --force' /bye >/dev/null 2>&1
            rm -f "$err"  # exec skips the EXIT trap
            exec ${pass}/bin/pass "$@"
            ;;
        esac
      fi
      exit "$rc"
    ''))
    passage
    age
    age-plugin-fido2-hmac
    qtpass
    pwgen

    unetbootin

    teensy-loader-cli
    #unstable.qmk_firmware

    #Accessories
    piper
    android-file-transfer
    go-mtpfs

    sweethome3d.application

    #Terminal system tools
    lm_sensors
    picocom

    gnome.gvfs
    gtk3
    gsettings-desktop-schemas

    #virtualisation
    #virtmanager


    awscli

    #samba4Full
    cifs-utils

    ledger-live-desktop

    #hsphfpd

    vulkan-loader
    vulkan-validation-layers
    vulkan-tools

    swaybg
    grim
    wl-clipboard
    slurp

    obs-studio

    wireshark

    ghidra

    qFlipper

    prismlauncher
    libsecret

    ## LSP servers for opencode and other LLMs

    bash-language-server
    nil
    nixd
    pyright
    ruff
    rust-analyzer
    typescript

    handlr

    masterpdfeditor
    poppler-utils

    wine
    winetricks


    unstable.opencode
    nodejs
    gh

    devenv
    tmux

    syncthing
    obsidian
  ];

  /*environment.extraSetup = ''
    ln - s ${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0 $out/share
    '';*/

  programs = {
    nix-ld = {
      enable = true;
      libraries = with pkgs; [
        gtk3
        libnotify
        nss
        libsecret

      ];
    };
    ssh = {
      #package = pkgs.openssh.override { dsaKeysSupport = true; };
      startAgent = false;

      extraConfig = ''
        
      '';
    };

    steam.enable = false;  # Temporarily disabled due to inode exhaustion

    wireshark.enable = true;

    chromium = {
      enable = true;
      extensions = [
        "cjpalhdlnbpafiamejdnhcphjbkeiagm" # uBlock Origin
        "pkehgijcmpdhfbdbbnkijodmdjhbjlgp" # Privacy Badger
        "ldpochfccmkkmhdbclfhpagapcfdljkj" # Decentraleyes
        "naepdomgkenhinolocfifgehidddafch" # Browserpass
        "edibdbjcniadpccecjdfdjjppcpchdlm" # I still don't care about cookies
        "oboonakemofpalcgghocfoadofidjkkk" # KeePassXC-Browser (bridges to fafnir-keepassxc-bridge)
        "fcoeoabgfenejglbffodgkkbkcdhcgfn" # Claude in Chrome


      ];
      defaultSearchProviderSearchURL = "https://duckduckgo.com/?q=%s";
      defaultSearchProviderSuggestURL = "https://duckduckgo.com/?q=%s";
      homepageLocation = "about:blank";
      extraOpts = {
        CommandLineFlagSecurityWarningsEnabled = false;
      };
    };

    browserpass = {
      enable = true;
    };

    firefox = {
      enable = true;
      policies = {
        ExtensionSettings = {
          # KeePassXC-Browser, bridges to fafnir-keepassxc-bridge via the
          # org.keepassxc.keepassxc_browser native-messaging manifest
          # installed by services.fafnir-keepassxc-bridge.
          "keepassxc-browser@keepassxc.org" = {
            installation_mode = "force_installed";
            install_url = "https://addons.mozilla.org/firefox/downloads/latest/keepassxc-browser/latest.xpi";
          };
        };
      };
    };

    gnupg = {
      agent = {
        enable = true;
        #pinentryFlavor = "qt";
        pinentryPackage = pkgs.pinentry-qt;
        #enableBrowserSocket = true;
        enableExtraSocket = true;
        enableSSHSupport = false;
      };
      #package = pkgs.unstable.gnupg;
    };

    #firejail = {
    #  enable = true;
    #};


  };


  nixpkgs.config = {
    allowBroken = true;
    chromium = {
      #enableAdobeFlash = true;
      #enablePepperPDF = true;
      enableWideVine = true; #Still broken
      pulseSupport = true;
      #enableVaapi = true;
    };
    firefox = {
      #enableAdobeFlash = true;
      enableWideVine = true;
      #enableVLC = true;
    };
    packageOverrides = pkgs: {
      vaapiIntel = pkgs.vaapiIntel.override { enableHybridCodec = true; };
    };

  };


  # avahi.nssmdns puts mdns_minimal before files, so every lookup of the local
  # hostname blocks ~5s on mDNS when DNS/network is down (10s zsh startup).
  # files/myhostname first; mdns still precedes dns so .local never hits DNS.
  system.nssDatabases.hosts = lib.mkForce [
    "files"
    "mymachines"
    "myhostname"
    "mdns_minimal [NOTFOUND=return]"
    "dns"
    "mdns"
  ];

  services = {
    samba = {
      enable = false;
      package = pkgs.samba4Full;
    };
    gvfs.enable = true;
    printing = {
      enable = true;
      drivers = with pkgs; [ postscript-lexmark ];
      # cups-browsed pinned cups.service permanently alive via an hourly IPP
      # Renew-Subscription (the only cups activity in the journal; no print
      # jobs). Without it cups socket-activates on demand and idles out.
      # Network printers must be added manually instead of auto-discovered.
      browsed.enable = false;
    };
    avahi = {
      nssmdns4 = true;
      nssmdns6 = true;
      enable = true;
      publish = {
        enable = false;
      };
    };

    #dbus.packages = [ pkgs.hsphfpd ];

    pipewire =
      {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
        # If you want to use JACK applications, uncomment this
        jack.enable = true;

        wireplumber = {
          enable = true;
        };

      };

    #passSecretService.enable = true;
  };



  # GTK theming configuration moved to appearance.nix

  virtualisation = {
    docker = {
      enable = true;
      # docker.socket activates dockerd on first `docker` command; keeps
      # docker.service off the network-online.target boot critical chain.
      # No containers use restart policies today, so nothing auto-starts
      # that would be lost.
      enableOnBoot = false;
      # --volumes intentionally omitted: would delete local DB volumes.
      autoPrune = {
        enable = true;
        dates = "weekly";
        flags = [ "--all" ];
      };
      #extraOptions = ''
      #    --storage-opt dm.basesize=20G
      #  '';
    };
    waydroid = {
      enable = false;
    };
  };
  # Additional fonts beyond the main appearance configuration
  fonts.packages = with pkgs; [
    corefonts
    google-fonts
    hack-font
    powerline-fonts
    emacs-all-the-icons-fonts
    winePackages.fonts
    tratex-font
    dejavu_fonts
    liberation_ttf
    ubuntu-classic
    noto-fonts-cjk-sans
    ibm-plex
    nerd-fonts.fira-code
    nerd-fonts.blex-mono
  ];
  services = {

    #upower.enable = true;
    nscd.enable = true;

    # tor removed 2026-06: zero circuits in the journal, SOCKS listener on
    # 127.0.0.1:9050 had no clients. Re-enable ad-hoc if torsocks is needed.
    # gpm removed 2026-06: console-mouse daemon is pointless under Wayland
    # and was a root process with raw /dev/input/mice access.

    openssh.settings.X11Forwarding = true;

    gnome.gcr-ssh-agent.enable = false;

    #udisks2.enable = true;
    devmon.enable = true;

    pcscd = {
      enable = true;
      plugins = [ pkgs.ccid ];
    };

    ratbagd = {
      enable = true;
    };

    udev = {
      packages = [
        pkgs.libu2f-host
        pkgs.yubikey-personalization
        pkgs.yubico-piv-tool
        pkgs.yubikey-manager
        pkgs.pcsc-tools
        pkgs.opensc
        #pkgs.bash
        pkgs.usb-modeswitch-data
        pkgs.ledger-udev-rules
        # pkgs.android-udev-rules # Removed - superseded by built-in systemd uaccess rules
      ];


      extraRules = ''


        	SUBSYSTEMS=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="5740", ATTRS{manufacturer}=="Flipper Devices Inc.", TAG+="uaccess"
        #Flipper Zero DFU
        SUBSYSTEMS=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="df11", ATTRS{manufacturer}=="STMicroelectronics", TAG+="uaccess"
        #Flipper ESP32s2 BlackMagic
        SUBSYSTEMS=="usb", ATTRS{idVendor}=="303a", ATTRS{idProduct}=="40??", ATTRS{manufacturer}=="Flipper Devices Inc.", TAG+="uaccess"

                # this udev file should be used with udev 188 and newer
                ACTION!="add|change", GOTO="u2f_end"

                # Yubico YubiKey
                KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1050", ATTRS{idProduct}=="0113|0114|0115|0116|0120|0402|0403|0406|0407|0410", MODE="0660", GROUP="plugdev", TAG+="uaccess"

                LABEL="u2f_end"
                # G29
                #SUBSYSTEMS=="hidraw", KERNELS=="0003:046D:C24F.????", DRIVERS=="logitech", MODE="0660", TAG+="uaccess"

                # Logitech G29 Driving Force Racing Wheel
                #SUBSYSTEMS=="hid", KERNELS=="0003:046D:C24F.????", DRIVERS=="logitech" , MODE="0660", TAG+="uaccess", RUN+="${pkgs.stdenv.shell} -c 'chmod 666 %S%p/../../range; chmod 777 %S%p/../../leds/ %S%p/../../leds/*; chmod 666 %S%p/../../leds/*/brightness'"
                #SUBSYSTEMS=="hid", KERNELS=="0003:046D:C24F.????", DRIVERS=="logitech" , MODE="0660", TAG+="uaccess", RUN+="${pkgs.stdenv.shell} -c 'chmod 666 %S%p/../../../range; chmod 777 %S%p/../../../leds/ %S%p/../../../leds/*; chmod 666 %S%p/../../../leds/*/brightness'"
                SUBSYSTEMS=="hid", KERNELS=="0003:046D:C24F.????", DRIVERS=="logitech", RUN+="${pkgs.stdenv.shell} -c 'cd %S%p/../../../; echo 65535 > autocenter; chmod 666 alternate_modes combine_pedals range gain autocenter spring_level damper_level friction_level ffb_leds peak_ffb_level leds/*/brightness; chmod 777 leds/ leds/*'"
      '';

    };

    redshift = {
      enable = false;
    };

    syncthing = {
      enable = true;
      user = "jonas";
      dataDir = "/home/jonas/syncthing";
    };

  };

  nixpkgs.config.permittedInsecurePackages = [
    "electron_24"
    #"p7zip-16.02"
    #"openssl-1.1.1u"
  ];

}
