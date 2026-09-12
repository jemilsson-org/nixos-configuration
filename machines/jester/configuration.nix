{ config, lib, pkgs, stdenv, hyprland, nix-build-router, ... }:
let
  #containers = import ./containers/containers.nix { pkgs = pkgs; config = config; stdenv = stdenv; };
  #cardano-node = removed - no longer needed
  #cardano-hw-cli = removed - no longer needed  
  vpp = pkgs.jemilsson.vpp;
  claudia = pkgs.jemilsson.claudia;
  fit-web = pkgs.jemilsson.fit-web;
  fit-entire-website = pkgs.jemilsson.fit-entire-website;
  fit-main = pkgs.jemilsson.fit-main;

  wg2IPv4Prefixes = [
    { prefix = "10.128.12.0/24"; }
    { prefix = "10.0.0.0/8"; }
    { prefix = "100.64.0.0/10"; }
    { prefix = "192.168.0.0/16"; }
    { prefix = "172.16.0.0/12"; }
    { prefix = "160.79.104.0/23"; }  # Claude code
    { prefix = "137.61.9.13/32"; }   # skatteverket.se
    { prefix = "137.61.9.10/32"; }   # www7.skatteverket.se
  ];

  wg2IPv6Prefixes = [
    { prefix = "2a12:5800:0:27::/64"; }
    { prefix = "2a12:5800::/29"; }
    { prefix = "2a05:d016:865:7a00::/56"; }
    { prefix = "2607:6bc0::/48"; }   # Claude code
    { prefix = "2a03:b100:a:9::b/128"; }  # skatteverket.se
    { prefix = "2a03:b100:a:9::a/128"; }  # www7.skatteverket.se
    { prefix = "::/0"; metric = 50000; }
  ];

  parsePrefix = s: let
    parts = lib.splitString "/" s;
  in {
    address = builtins.elemAt parts 0;
    prefixLength = lib.toInt (builtins.elemAt parts 1);
  };

  prefixToRoute = p: let
    parsed = parsePrefix p.prefix;
  in parsed // lib.optionalAttrs (p ? metric) {
    options.metric = toString p.metric;
  };

  wg2AllowedIPs = map (p: p.prefix) (wg2IPv4Prefixes ++ wg2IPv6Prefixes);
  wg2IPv4Routes = map prefixToRoute wg2IPv4Prefixes;
  wg2IPv6Routes = map prefixToRoute wg2IPv6Prefixes;
in
{
  imports = [
    #<nixos-hardware/lenovo/thinkpad/x1/7th-gen>
    ../../config/laptop_base.nix
    ../../config/services/kvm/kvm.nix
    ../../config/i3_x11.nix
    ../../config/language/english.nix
    #../../config/software/tensorflow.nix
    #../../packages/vpp/vpp.nix
    ./hardware-configuration.nix
    #./graphiti.nix
    #./mcpo.nix
    ./camera.nix
    ./room-watch.nix
    ./presence-lock.nix
    ./netns-claude-glecom.nix
    ./pi-lens.nix
    ./nix-retry.nix
    ../../config/mx-debounce.nix

  ];

  nixpkgs.config.permittedInsecurePackages = [
                #"electron-24.8.6"
];

  # Hardware-attested SSH key enforcement. syna installs and gates
  # authorized_keys for every privileged user from the shared keys file.
  # See ../../config/syna/attestations/README.md for how to refresh the
  # fafnir bundle.
  services.syna = {
    package = pkgs.syna;
    ssh = {
      enable = true;
      level = "fail";
      userKeys = import ../../config/syna/keys.nix;
    };
  };



  #programs.sway.extraOptions = [
  #  "WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0"
  #];

  #programs.sway.extraSessionCommands = ''
  #  WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0
  #'';


  environment.variables = {
    WLR_DRM_DEVICES = "/dev/dri/card0:/dev/dri/card1";
    #WLR_BACKEND = "vulkan";
    # Interactive cargo only (nix-build sandbox scrubs env, so determinism
    # of nix-built derivations is unaffected). sccache caches rustc output
    # to S3; mold cuts link time on big Rust workspaces.
    RUSTC_WRAPPER = "sccache";
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS = "-C link-arg=-fuse-ld=mold";
    # Cap cargo parallelism at 8 of 12 cores so interactive work stays
    # responsive and 8 concurrent rustc+mold pairs fit in RAM. An env var
    # (not ~/.cargo/config.toml) so it reaches every cargo: the rustup
    # toolchain in ~/.cargo/bin shadows the nice'd wrapper from base.nix,
    # and devenv shells bring their own cargo too. One-off override:
    # cargo build -j12 (CLI beats env).
    CARGO_BUILD_JOBS = "8";
    # Hard resource caps for interactive cargo/rustc, enforced by the base.nix
    # cargo wrapper which launches into a transient systemd --user scope so the
    # whole cargo+rustc+mold tree is one bounded cgroup. -j8 + nice 19 only cap
    # parallelism and priority; these cap actual RAM/CPU so a single fat crate
    # (LTO, codegen-units=1) can't balloon past the session's headroom on this
    # 31 GiB / 12-core box. MemoryHigh throttles via reclaim, MemoryMax is the
    # hard OOM-kill ceiling for the build cgroup; CPUQuota caps at ~8 cores even
    # if a build spawns more than 8 concurrent rustc. Only reaches this wrapper
    # (rustup/devenv cargos shadow it, same caveat as CARGO_BUILD_JOBS above);
    # nix builds are unaffected (no $XDG_RUNTIME_DIR in the sandbox).
    CARGO_MEMORY_HIGH = "16G";
    CARGO_MEMORY_MAX = "20G";
    CARGO_CPU_QUOTA = "800%";
    # Same cgroup-scope treatment for CBMC (base.nix cbmc wrapper): cap at ~8 of
    # 12 cores so interactive work stays responsive while a model check runs.
    CBMC_CPU_QUOTA = "800%";
    SCCACHE_BUCKET = "sccache-shared-723173433317";
    SCCACHE_REGION = "ap-southeast-7";
    SCCACHE_S3_KEY_PREFIX = "v0";
  };

  # Disabled: any kernelPatches entry forces a full from-source kernel rebuild
  # (no binary-cache match), which is slow on jester. Re-enable once the fix is
  # upstream and in a cached nixpkgs kernel, or serve a prebuilt patched kernel
  # from a Nix binary cache.
  # boot.kernelPatches = [
  #   {
  #     name = "intel-mst-reprobe-fix";
  #     patch = ./intel-mst-reprobe-fix.patch;
  #   }
  # ];

  boot.initrd.kernelModules = [ "i915" ];
  boot.blacklistedKernelModules = [ "pn533_usb" "pn533" "xe" ];

  boot.kernel.sysctl."net.ipv4.tcp_mtu_probing" = 1;

  # Hyprland crashes on this machine are GPU context resets: the GPU driver
  # resets the Iris Xe GPU, glGetGraphicsResetStatus() then returns
  # GL_GUILTY_CONTEXT_RESET, and Hyprland aborts (it has no GL context
  # recovery). The kernel-side reset reason (guilty engine / error code) is
  # what we actually need, but base.nix caps journald at 500M which only
  # retains ~1 day, so the reset message rotates out before it can be read.
  # mkAfter ensures this SystemMaxUse wins over base.nix's (last key wins in
  # journald.conf). Bump retention so the next reset's signature is captured.
  services.journald.extraConfig = lib.mkAfter ''
    SystemMaxUse=4G
    MaxRetentionSec=2week
  '';

  # Memory-pressure hardening.
  #
  # jester has 31 GiB RAM and previously ran with ZERO swap. Under load
  # (rustc/nix builds + the local AI-gateway services + chromium/electron)
  # the *kernel* global OOM killer fired (89 oom-kill invocations in the
  # journal, 80 in a single day) and culled the graphical session wholesale
  # (pipewire, dbus-broker, the xdg portals), which is what made hyprlock
  # "sometimes crash" - it dies as collateral when the stack it renders on is
  # wiped. systemd.oomd (enabled in base.nix) acts on cgroup PSI but the
  # kernel global OOM, with no swap to provide reclaim runway, fired first.
  #
  # Three privilege-correct levers (verified: a user process here CANNOT set a
  # negative oom_score_adj, so "protect the session" via negative OOMScoreAdjust
  # on user units is not an option; instead we add swap headroom and bias the
  # killer toward builds, which are the actual trigger):

  # 1. zram swap: compressed in-RAM swap gives the kernel reclaim headroom so a
  #    transient spike compresses idle anonymous pages instead of hard-OOMing.
  #    Raised 25 -> 50 (2026-06): at 25% the device sat 100% full (7.6G/7.8G,
  #    SwapFree ~0) while measured compression was 4.85:1, so a 15.5G device
  #    costs ~3.2G RAM at this workload for +7.7G reclaim headroom. The
  #    worst-case-incompressible assumption behind "kept conservative" did not
  #    hold in practice; monitor `zramctl` mem_used_total after workload changes.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    # 50 -> 80 (2026-06): device sat 100% full again (15.2G/15.5G, SwapFree ~0)
    # under concurrent rust-analyzer + solana-test-validator load while measured
    # compression held at ~4.7:1, so the RAM cost per GB of headroom stays cheap.
    # 80% gives ~24.8G compressed-swap headroom for ~5.3G real RAM at this ratio.
    memoryPercent = 80;
    priority = 100;
  };

  # 2. VM tuning for zram: favour compressing anonymous pages over evicting the
  #    page cache, and disable swap readahead (zram is random-access, readahead
  #    just wastes cycles). overcommit is left at the kernel default (0 here;
  #    NixOS does not set strict overcommit).
  boot.kernel.sysctl = {
    "vm.swappiness" = 100;
    "vm.page-cluster" = 0;
    # Default 10 gives kswapd a ~29MB reclaim span on the 29.6G Normal zone,
    # causing wake/sleep churn under constant zram pressure; 100 batches
    # reclaim in ~296MB spans (fewer cycles, helps zstd compression batching).
    "vm.watermark_scale_factor" = 100;
    # Bias reclaim toward dropping reclaimable slab (~2G dentry/inode here)
    # sooner vs page cache; cheap to refill on NVMe. Slab-vs-pagecache only;
    # anon-vs-file balance is governed by swappiness above. Do not exceed 200.
    "vm.vfs_cache_pressure" = 200;
  };

  # 3. Bias the OOM killer toward local nix builds, the real trigger. The user
  #    systemd manager (and thus the whole graphical session) runs at
  #    oom_score_adj=100, while root nix-daemon runs at 0 - i.e. an unconstrained
  #    rustc build was LESS killable than the session it was starving. Raise
  #    nix-daemon so builds are sacrificed first, and add a soft MemoryHigh so
  #    the kernel reclaims/throttles a fat build before any hard kill.
  systemd.services.nix-daemon.serviceConfig = {
    OOMScoreAdjust = 500;
    # Hard ceiling on LOCAL nix builds: the nix-daemon cgroup (where local
    # build jobs run) may never exceed 6 of 12 cores nor 16 GiB RAM, regardless
    # of any --cores/--max-jobs/-j flag a build passes. remote builders do the heavy
    # lifting; this keeps a local fallback (or a flag-forced build that slips
    # the hook) from saturating the box and starving the interactive session.
    # Memory: SOFT throttle only. MemoryHigh applies reclaim pressure around
    # 16 GiB but never kills. A hard MemoryMax here is DELIBERATELY avoided:
    # the daemon, its remote-build SSH coordination, and all local builds
    # share this one cgroup, so a memory.max OOM-kill (memory.oom.group=1)
    # would take out the daemon + every in-flight build atomically and wedge
    # the store (see the teleclaude note below — same rejected approach). A
    # true per-build hard cap needs nix use-cgroups + auto-allocate-uids
    # (experimental); not enabled here.
    MemoryHigh = "16G";
    # CPU: hard ceiling of 6 of 12 threads (throttle, never kills — safe on
    # the shared cgroup), at LOW priority so local builds yield to the
    # interactive session. CPUWeight is the cgroup-v2 lever (default 100; 10
    # gives builds ~1/10 of contended share); idle IO class keeps disk
    # responsive. The daemon already runs SCHED_IDLE (see base config), so no
    # Nice= is needed. remote builders do the heavy lifting; these only bound a
    # local fallback or a flag-forced build that slips the hook.
    CPUQuota = "600%";
    CPUWeight = 10;
    IOSchedulingClass = "idle";
  };

  # 4. Wire systemd-oomd to actual cgroups. base.nix enables the daemon but
  #    NixOS monitors zero slices by default (oomctl showed both
  #    monitored-cgroup lists empty), so it could never act and the kernel
  #    global OOM kept firing first (27 oom-kill invocations in 7 days).
  #    With slices monitored, oomd kills the highest sustained-pressure
  #    descendant cgroup (chromium/builds) at 80% pressure for 30s, before
  #    the kernel nukes the session. oomd ignores OOMScoreAdjust (kernel-only
  #    knob); ManagedOOMPreference is its protection mechanism, so mark the
  #    credential stack avoid-last.
  systemd.oomd = {
    enableSystemSlice = true;
    enableUserSlices = true;
  };
  systemd.user.services.fafnir.serviceConfig.ManagedOOMPreference = "avoid";
  systemd.user.services.fafnir-openpgp.serviceConfig.ManagedOOMPreference = "avoid";
  # Protect the Claude Code agent session (runs under teleclaude.service in
  # app.slice at oom_score~800 with ManagedOOMPreference=none, i.e. a default
  # oomd candidate). Mark it avoid-last so oomd sacrifices builds/chromium/the
  # AI gateway first; the agent is the system's control plane. oomd ignores
  # OOMScoreAdjust and a user service cannot set a negative one, so this
  # preference is the only available protection lever. Hard-capping nix-daemon
  # was rejected: MemoryMax on the shared build cgroup SIGKILLs the daemon and
  # all in-flight builds atomically, wedging the store; the existing
  # MemoryHigh=20G + OOMScoreAdjust=500 already bias builds as the OOM victim.
  systemd.user.services.teleclaude.serviceConfig.ManagedOOMPreference = "avoid";

  # /tmp lives on the root fs and had accumulated 71G/18k entries: a nightly
  # recursive /tmp scan refreshes atime on every entry (all sampled nix-shell
  # dirs shared an identical atime to the nanosecond), and under relatime that
  # defeats systemd-tmpfiles' age check (max of atime/mtime/ctime vs 10d).
  # noatime freezes atime so age falls back to real mtime/ctime age; f2fs
  # lazytime already deferred atime writes, so there is no I/O cost.
  # cleanOnBoot additionally wipes /tmp wholesale on every boot.
  fileSystems."/".options = [ "noatime" ];
  boot.tmp.cleanOnBoot = true;

  # Boot spent ~60s in NetworkManager-wait-online (network.target at 4s,
  # network-online.target at 64s on slow 2.4GHz association), gating docker,
  # clatd and teamviewerd and thus multi-user/graphical.target. Nothing here
  # actually needs network-online at boot: wg2's endpoint is a bare IP and
  # re-handshakes on first packet, and the rest are happy to start degraded.
  systemd.services.NetworkManager-wait-online.enable = false;

  # A WiFi flap storm restarts nscd once per resolvconf update; the default
  # start limit (5 in 10s) then latches nsncd off permanently, killing all
  # glibc name resolution until a manual restart (happened 2026-07-22).
  systemd.services.nscd.unitConfig.StartLimitIntervalSec = 0;

  # DPTF-aware thermal management (INT3400 zone present, policy was the crude
  # step_wise governor): thermald clamps via RAPL proactively, sustaining
  # turbo longer during compile bursts instead of frequency-cliff throttling.
  # TLP owns governor/EPP/platform_profile; thermald owns RAPL - no conflict.
  services.thermald.enable = true;

  # No WWAN modem in this machine; NetworkManager pulls ModemManager in via
  # mkDefault true. Saves a daemon and a per-boot probe.
  networking.modemmanager.enable = false;

  systemd.services.restart-fprintd-on-resume = {
    description = "Restart fprintd after resume from sleep";
    wantedBy = [ "post-resume.target" ];
    after = [ "post-resume.target" ];
    script = "systemctl restart fprintd";
    serviceConfig.Type = "oneshot";
  };

  systemd.tmpfiles.rules = [
    "L+    /opt/rocm/hip   -    -    -     -    ${pkgs.rocmPackages.clr}"
    # Seed portal-login's SSID -> pass-entry mapping on first boot only ("C"
    # copies just the once, unlike "L+"): the user is meant to edit this
    # in place afterwards without a rebuild overwriting it.
    "C     /home/jonas/.config/captive-portals.conf   0600   jonas   users   -   ${pkgs.writeText "captive-portals.conf" ''
      # SSID=pass-entry-name, one mapping per line. portal-login looks up
      # the currently connected SSID here, then runs `pass show <entry>`.
      TheUrbanCoWorking=wifi/TheUrbanCoWorking
    ''}"
  ];

  hardware.graphics.extraPackages = with pkgs; [
  vpl-gpu-rt
  ];
  # For 32 bit applications 
  # hardware.graphics.extraPackages32 = with pkgs; [
  #   # RADV is used by default, no need for amdvlk
  # ];

  /*
  age.rekey = {
    # Obtain this using `ssh-keyscan` or by looking it up in your ~/.ssh/known_hosts
    hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEtJIhxEVsyKN/7fUBN4DYFoU6wgMJZbC8+hZk7Rv4Cx";
    # The path to the master identity used for decryption. See the option's description for more information.
    masterIdentities = [ ../../age/jonas-yubikey-7447013.pub ];
    #masterIdentities = [ "/home/myuser/master-key" ]; # External master key
    #masterIdentities = [ "/home/myuser/master-key.age" ]; # Password protected external master key
  };

  age.secrets.secret1.rekeyFile = ./secrets/secret1.age;
  age.secrets.secret1.generator.script = "alnum";

  environment.etc."secret1" = {
    source = config.age.secrets.secret1.path;
  };
  */
  
  #users.users.user1.passwordFile = config.age.secrets.secret1.path;

  system.stateVersion = "23.05";

  # Run nixos-upgrade hourly (overrides base.nix's "Mon..Fri 02:00") to track
  # the hourly claude-code input bumps. Shrink the randomized delay from base's
  # 1h so runs don't bunch toward the next hour's window.
  system.autoUpgrade.dates = lib.mkForce "hourly";
  system.autoUpgrade.randomizedDelaySec = lib.mkForce "10m";

  boot = {
    extraModulePackages = with config.boot.kernelPackages; [ acpi_call ];
    kernelModules = [ "acpi_call" "uhid" ];
    # The AX211 BT controller autosuspends after ~2s idle; waking it stacks
    # on top of the MX Anywhere 3S's own sleep-reconnect latency and can eat
    # the first click after idle. Keep the controller awake (small idle-power
    # cost). Takes effect on reboot (module load time option).
    extraModprobeConfig = ''
      options btusb enable_autosuspend=0
    '';
    kernelParams = [
      "mem_sleep_default=s2idle"  # Only sleep mode available (firmware has no S3)
      # Disable Panel Self-Refresh on the i915 driver. Hyprland crashes here
      # have shown up as GPU context resets after which Hyprland's
      # glGetGraphicsResetStatus() returns GL_GUILTY_CONTEXT_RESET and it
      # aborts. PSR (panel self-refresh) failing to wake the display pipe is a
      # common trigger on mobile Iris Xe. Disabling PSR is the low-risk,
      # reversible first-line mitigation. Only cost is slightly higher idle
      # power. Remove if it does not help.
      "i915.enable_psr=0"
      # The f2fs root has its "needs fsck" checkpoint flag set (crashes Jul
      # 2026), so fsck.f2fs escalates to a full multi-hour scan every boot.
      # Skip it until a full check can run to completion overnight; kernel
      # mount-time crash recovery still runs. Remove after a clean full fsck.
      "fsck.mode=skip"
    ];
    loader = {
      systemd-boot =
        {
          enable = true;
          graceful = true;
        };
      efi.canTouchEfiVariables = true;
    };
    #kernelPackages = pkgs.linuxPackages_6_6;
    #kernelPackages = pkgs.unstable.linuxPackages_latest;

    binfmt.emulatedSystems = [ ];
  };

  # Shorter page-scan intervals while connectable: the MX Anywhere 3S sleeps
  # after idle and must reconnect on the next click; FastConnectable narrows
  # that window so the wake-up click is less likely to be lost. Merges into
  # the shared bluetooth settings from desktop_base.nix.
  hardware.bluetooth.settings.General.FastConnectable = true;

  # HUAWEI FreeBuds 6 (LE Audio capable) broke the whole bluetooth audio
  # stack: wireplumber offered BAP/LC3 ("trying to set invalid profile 3,
  # codec 256") but bluez without Experimental cannot create ISO
  # transports (kernel ISO sockets stay unregistered, errno 93), and the
  # failed negotiation tore down the classic bearer too - HFP RFCOMM
  # flapped every 3s (bluetoothd getpeername ENOTCONN) and no bluez card
  # appeared. Enabling bluez experimental D-Bus interfaces plus the
  # kernel ISO-socket feature fixes classic audio (A2DP AAC + HFP CVSD
  # mic, both verified live) and unlocks LE Audio; LC3 additionally
  # needs the buds re-paired over LE. The AX211 supports cis-central/
  # cis-peripheral. mSBC stays disabled: the buds negotiate CVSD anyway.
  # Wear-detection media auto-pause daemon (protocol notes in the
  # script). Restarts on failure; idles retrying while buds are away.
  systemd.user.services.freebuds-autopause = {
    description = "FreeBuds 6 in-ear auto-pause";
    wantedBy = [ "default.target" ];
    path = [ pkgs.playerctl ];
    serviceConfig = {
      ExecStart = "/run/current-system/sw/bin/freebuds-autopause";
      Restart = "on-failure";
      RestartSec = 10;
    };
  };

  hardware.bluetooth.settings.General.Experimental = true;
  hardware.bluetooth.settings.General.KernelExperimental = true;
  # bluez 5.87: adds Device1.PreferredBearer (experimental), needed to
  # force the LE bearer on dual-mode devices like the FreeBuds 6 -
  # without it every connection lands on BR/EDR and BAP/LC3 is
  # unreachable. Drop the override once nixpkgs ships >= 5.87.
  hardware.bluetooth.package = pkgs.bluez.overrideAttrs (old: {
    version = "5.87";
    src = pkgs.fetchurl {
      url = "https://www.kernel.org/pub/linux/bluetooth/bluez-5.87.tar.xz";
      sha256 = "0pxk6960ri929p2yn236zqawbw3y0dmn0l48b5phqcfpxcnczg96";
    };
    # btctl-noninteractive: merged upstream in 5.87.
    # lreadline: hunks fail on 5.87's Makefile.tools; NIX_LDFLAGS below
    # replaces it (with --as-needed the extra linkage is free).
    patches = builtins.filter (
      p:
      !(pkgs.lib.hasInfix "btctl-noninteractive" (baseNameOf p))
      && !(pkgs.lib.hasInfix "lreadline" (baseNameOf p))
    ) (old.patches or [ ]);
    NIX_LDFLAGS = (old.NIX_LDFLAGS or "") + " -lreadline";
    # test-textfile's delete assertion fails on the remote builder's
    # overlayfs; upstream tests, not our code - skip for this override.
    doCheck = false;
  });
  services.pipewire.wireplumber.extraConfig."51-bluez" = {
    "monitor.bluez.properties" = {
      "bluez5.enable-msbc" = false;
      "bluez5.enable-sbc-xq" = true;
    };
  };

  # Disambiguate the two RTK USB-C panels (they ship with identical EDID
  # serials, which confuses wlroots/Hyprland and prevents distinct
  # per-output position rules). The kernel-assigned DP connector names
  # are unstable across reboots (we've seen DP-5/DP-6 and DP-7/DP-8),
  # but the two panels always land on adjacent connectors. Override every
  # odd DP-N: exactly one of the two panels picks up the modified EDID,
  # the other keeps its native one, so they end up with distinct serials.
  hardware.display.outputs."DP-1".edid = "rtk-dp8.bin";
  hardware.display.outputs."DP-3".edid = "rtk-dp8.bin";
  hardware.display.outputs."DP-5".edid = "rtk-dp8.bin";
  hardware.display.outputs."DP-7".edid = "rtk-dp8.bin";
  hardware.display.outputs."DP-9".edid = "rtk-dp8.bin";
  hardware.display.outputs."DP-11".edid = "rtk-dp8.bin";
  hardware.display.edid.packages = [
    (pkgs.runCommand "rtk-edid" { } ''
      mkdir -p "$out/lib/firmware/edid"
      cp ${./edid/rtk-dp8.bin} "$out/lib/firmware/edid/rtk-dp8.bin"
    '')
  ];

  # The EHOMEWEI X1 Pro dual monitor (RTK scaler, EDID mfr/product bytes
  # 4a 8b 60 25) trains DP alt mode at 2 of 4 lanes even though sink and
  # port support 4, halving MST bandwidth so the second panel falls back
  # to 1080p. When its EDID is present, force 4 lanes on the i915 DP base
  # connectors and retrain; restore auto negotiation when another DP sink
  # appears so docks and other monitors keep normal link training. Workaround
  # pending an i915 sink quirk. If the monitor was attached at boot it may
  # need one cable replug: the compositor rejects the full mode until a
  # fresh connect on the already-forced link.
  services.udev.extraRules =
    let
      ehomewei-lanes = pkgs.writeShellScript "ehomewei-lanes" ''
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep ]}
        rtk=0 other=0
        for edid in /sys/class/drm/card*-DP-*/edid; do
          [ -s "$edid" ] || continue
          id=$(od -A n -t x1 -j 8 -N 4 "$edid" 2>/dev/null | tr -d ' \n')
          if [ "$id" = "4a8b6025" ]; then rtk=1; else other=1; fi
        done
        # Keep the 4-lane force armed while nothing else is connected, so
        # the X1 Pro's next attach trains 4-lane directly (no retrain
        # cycle, ~1-2 s faster). Restore auto (with retrain) only when a
        # different DP sink appears.
        for dbg in /sys/kernel/debug/dri/*/DP-*; do
          f="$dbg/i915_dp_force_lane_count"
          [ -e "$f" ] || continue
          if [ "$rtk" = 1 ]; then
            if ! grep -q '\[4' "$f"; then
              printf 4 > "$f"
              printf 1 > "$dbg/i915_dp_force_link_retrain" 2>/dev/null || true
            fi
          elif [ "$other" = 1 ] && ! grep -q '\[auto' "$f"; then
            printf auto > "$f"
            printf 1 > "$dbg/i915_dp_force_link_retrain" 2>/dev/null || true
          fi
        done
      '';
    in
    ''
      ACTION=="change", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", RUN+="${ehomewei-lanes}"
    '';

  networking = {
    hostName = "jester";
    getaddrinfo.enable = false;

    bridges = {
      br0 = {
        interfaces = [ ];
      };
      br1 = {
        interfaces = [ ];
      };
    };

    wireguard = {
      interfaces = {
        /*
          wg0 = {
          ips = [ "10.50.0.37/32" ];
          peers = [
          {
          publicKey = "IR9lBjFR2qX4UmgML5oBykUgrAzqOzhaNpF+xjD8L3k=";
          allowedIPs = [
          "10.50.0.0/16"
          ];
          endpoint = "13.48.43.75:123";
          }

          ];
          };
        
          wg1 = {
          privateKeyFile = "/var/lib/wireguard/privatekey";
          generatePrivateKeyFile = true;
          ips = [ "10.111.255.253/32" "10.112.255.253/32" ];
          peers = [
          {
          publicKey = "zYgI7WYsKHNh70oZvdHDPKCeqKeEdsQbAIxtlNGSw2c=";
          allowedIPs = [
          "10.111.0.0/16"
          ];
          endpoint = "18.198.12.235:123";
          }

          {
          publicKey = "Uv6JEWpVPBAt44WBRWmyGRYtF0k7mYm2vRKmkOArtUw=";
          allowedIPs = [
          "10.112.0.0/16"
          ];
          endpoint = "54.75.127.255:123";
          }

          ];
          };

        */

        
          
          wg2 = {
          privateKeyFile = "/var/lib/wireguard/privatekey";
          allowedIPsAsRoutes = false;
          metric = 100;
          ips = [ "10.128.12.3/24" "2a12:5800:0:27::3/64" ];
          peers = [
          {
          publicKey = "kCvTCiqn4/mhkbWF9eKaTycAp7yHfkMYu3uEuuneFFc=";
          allowedIPs = wg2AllowedIPs;
          endpoint = "194.26.208.1:51822";
          }
          ];
          };
        
        /*

          
          wg3 = {
          privateKeyFile = "/var/lib/wireguard/privatekey";
          ips = [ "10.128.12.3/24" "2a12:5800:0:27::3/64" ];
          peers = [
          {
          publicKey = "Z712joOcYZDyiJrynswegnIlRsebKrIskvw2rOIBX2Y=";
          allowedIPs = [
                "10.128.12.0/24"
                "2a12:5800:0:27::/64"
                "10.0.0.0/8"
                "172.16.0.0/12"
                "192.168.0.0/16"
                "100.64.0.0/10"
                "192.121.29.0/24"
                "194.26.208.0/24"
                "2a12:5800::/29"
                #"0::/0"
                #"0.0.0.0/0"
                
              ];
          endpoint = "194.26.208.43:53";
          }
          ];
          };

          */
        	



      };
    };

    interfaces = {
      #"enp48s0u2u1.102" = {
      #  useDHCP = true;
      #};
      #"enp48s0u2u1.150" = {
      #  useDHCP = true;
      #};

      wlp0s20f3.ipv4.routes = [
        {
            address = "194.26.208.1";
            prefixLength = 32;

        }
        {
            address = "194.26.208.43";
            prefixLength = 32;

        }
      ];
      wg2.ipv4.routes = wg2IPv4Routes;
      wg2.ipv6.routes = wg2IPv6Routes;
    };

    vlans = {
      #"enp48s0u2u1.102" = {
      #  id = 102;
      #  interface = "enp48s0u2u1u2";
      #};
      #"enp48s0u2u1.150" = {
      #  id = 150;
      #  interface = "enp48s0u2u1u2";
      #};
    };

  dhcpcd = {
    enable = true;
    extraConfig = "
    define 108 uint32 ipv6only_preferred
    request ipv6only_preferred
    ";
  };

  networkmanager.dispatcherScripts = [
    {
      type = "basic";
      source = pkgs.replaceVars ./prefer-ipv4-fallback.sh {
        iputils = pkgs.iputils;
        gawk = pkgs.gawk;
      };
    }
    {
      type = "basic";
      source = pkgs.writeShellScript "wg2-portal-pause" ''
        [ "''${2:-}" = "connectivity-change" ] || exit 0
        case "''${CONNECTIVITY_STATE:-}" in
          # Units are not PartOf the target, so stop them by glob; the link
          # deletion in wireguard-wg2.service's ExecStop removes the routes.
          PORTAL) systemctl stop 'wireguard-wg2*.service' ;;
          # Restarting the target pulls both services back in via WantedBy.
          # Guard on the link so routine FULL transitions don't churn wg2.
          FULL)
            ${pkgs.iproute2}/bin/ip link show wg2 >/dev/null 2>&1 \
              || systemctl restart wireguard-wg2.target
            ;;
        esac
      '';
    }
    {
      type = "basic";
      # wg2 blanket-routes RFC1918, which swallows the local network's own
      # DHCP DNS servers when they sit outside the on-link subnet (seen at
      # TheUrbanCoWorking: DNS 10.3.1.100 behind gateway 10.3.170.1, so all
      # name resolution died into the tunnel while wg2 was up). Pin /32
      # exception routes for the DHCP DNS servers via the interface gateway.
      source = pkgs.writeShellScript "dns-route-exceptions" ''
        [ "''${1:-}" = "wlp0s20f3" ] || exit 0
        case "''${2:-}" in up|dhcp4-change) ;; *) exit 0 ;; esac
        gw="''${DHCP4_ROUTERS%% *}"
        [ -n "$gw" ] || gw="''${IP4_GATEWAY:-}"
        [ -n "$gw" ] || exit 0
        for ns in ''${IP4_NAMESERVERS:-}; do
          # Skip nameservers already on-link; the kernel route covers them.
          ${pkgs.iproute2}/bin/ip route replace "$ns/32" via "$gw" dev wlp0s20f3 metric 50 2>/dev/null || true
        done
      '';
    }
  ];

  };

  services = {
    xserver = {
      videoDrivers = [ "modesetting" ];
    };
    undervolt = {
      enable = false;
    };

    fprintd = {
      enable = true;
    };

    # ofono (telephony) and teamviewer removed 2026-06: ofono had no hardware
    # to manage (Wi-Fi-only machine, daemon sat inactive) and teamviewer had
    # zero sessions in the journal while keeping a 37-thread daemon resident.
    # Re-add services.teamviewer.enable = true if remote support is needed.

    clatd = {
      enable = true;
      settings = {
        plat-prefix = "64:ff9b::/96";
      };
    };

  };

  # Pause wg2 while a captive portal is unauthenticated. wg2 blanket-routes
  # RFC1918 (10/8, 172.16/12, 192.168/16) and an IPv6 default into the tunnel,
  # so on a portal network numbered from those ranges the portal's own login
  # servers are routed into a tunnel that cannot handshake yet (confirmed via
  # pcap 2026-07-22: every SYN encapsulated to the wg2 endpoint, zero replies).
  # Stopping the target deletes the wg2 link and with it those routes; FULL
  # restores it (start on an active target is a no-op). Claude-netns traffic
  # via table 200 pauses with it, which is moot while the portal blocks it.
  # Script merged into networking.networkmanager.dispatcherScripts below.

  # Captive-portal login browser: isolated Chromium bound to the Wi-Fi
  # interface, resolving via the portal's own DHCP DNS, so login pages load
  # even when wg2 routes, the prefer-IPv4 script, or the main browser profile
  # would break them. Launched by the dispatcher in laptop_base.nix.
  programs.captive-browser = {
    enable = true;
    interface = "wlp0s20f3";
  };

  networking.firewall.extraCommands = ''
    # Allow IPv6 forwarding for clatd
    ip6tables -I FORWARD -i clat -j ACCEPT
    ip6tables -I FORWARD -o clat -j ACCEPT
  '';

  environment.systemPackages = with pkgs; [
    # FreeBuds control (ANC, battery, gestures, quality preference) over
    # SPP. Two fixes pending upstream: the wrapper misses the `packaging`
    # dep (openfreebuds#93-style packaging bug), and FreeBuds 6 is not in
    # the model registry - the 6i driver speaks its protocol fine
    # (verified: battery/ANC/gestures/quality all work on BTFT0020).
    (openfreebuds.overridePythonAttrs (old: {
      dependencies = old.dependencies ++ [ python3Packages.packaging ];
      postPatch = (old.postPatch or "") + ''
        substituteInPlace openfreebuds/driver/constants.py \
          --replace-fail '"HUAWEI FreeBuds 6i": OfbDriverHuawei6I,' \
            '"HUAWEI FreeBuds 6i": OfbDriverHuawei6I,
    "HUAWEI FreeBuds 6": OfbDriverHuawei6I,'
      '';
    }))
    # In-ear wear detection -> media auto-pause for the FreeBuds 6
    # (reverse-engineered SPP protocol; see freebuds-autopause.py).
    (pkgs.writers.writePython3Bin "freebuds-autopause" { flakeIgnore = [ "E501" ]; }
      (builtins.readFile ./freebuds-autopause.py))
    # CLI login for the ANTlabs portal at The Urban Office (blocks its own
    # DNS and login server pre-auth; only the gateway works). Looks up the
    # active SSID in ~/.config/captive-portals.conf (seeded below) to find a
    # pass(1) entry, then reads the username/password from the password
    # store -- see portal-login.py's docstring for the assumed entry format.
    (pkgs.writers.writePython3Bin "portal-login" { flakeIgnore = [ "E501" ]; }
      (builtins.readFile ./portal-login.py))

    # Hyprland monitor hotplug pipeline (repo-managed copies; hyprland.conf
    # exec-once runs these by name). setup regenerates monitors.conf/.lua and
    # reloads only when the layout changed; events debounces hotplug bursts.
    (pkgs.writers.writePython3Bin "hypr-monitor-setup" { flakeIgnore = [ "E501" "W503" "W504" ]; }
      (builtins.readFile ./hypr/monitor-setup.py))
    (pkgs.writeShellScriptBin "hypr-monitor-events"
      (builtins.readFile ./hypr/handle-monitor-events.sh))
    # Credential store read by portal-login; not otherwise on PATH.
    pass
    cargo-sweep
    # Wrapper scopes AWS_PROFILE=sccache-shared to sccache invocations only
    # so it doesn't bleed into other AWS-aware tools in the shell.
    # nice 10: the sccache server persists in the interactive terminal scope
    # at nice 0, competing with keystrokes; 10 yields to interactive work
    # while staying above cargo builds (nice 19 via the base.nix wrapper).
    (writeShellScriptBin "sccache" ''
      export AWS_PROFILE=sccache-shared
      exec ${coreutils}/bin/nice -n 10 ${sccache}/bin/sccache "$@"
    '')
    mold
    docker
    docker-compose
    ffmpeg
    #python37Packages.imutils
    #python37Packages.scipy
    #python37Packages.shapely
    opencl-headers
    labelImg
    tesseract5  # OCR tool with all language support

    #bambu-studio
    #orca-slicer

    #pkgsCross.armv7l-hf-multiplatform.buildPackages.targetPackages.glibc

    #cardano-node
    #cardano-hw-cli

    vulkan-validation-layers

    #vpp
    
    #claudia
    
    # fit-web  # Needs additional dependencies
    # fit-entire-website  # Needs additional dependencies
    # fit-main  # Main FIT GUI application (needs work)

    # chromium is in desktop_base.nix with --remote-debugging-port=9222

    unstable.telegram-desktop
    whatsapp-electron

    bun
    sox

    claude-code

    nix-tcp-proxy

    # Opt-in sizing path: the closure-build-daemon unix socket is the BUILD STORE.
    # Eval is local (--eval-store auto); the build op (BuildDerivation, op36) goes
    # to the daemon, which peeks the inline derivation, classifies its weight, and
    # signals the gateway so it provisions a VM sized to the build. The daemon then
    # proxies the build to the gateway-provisioned builder.
    # NO --builders / --max-jobs 0 here: those would shunt the build op to a
    # separate ssh-ng builder, bypassing the daemon's peek (always Medium + the
    # op31 peek-then-stop deadlock). The daemon IS the builder via its gateway proxy.
    # Default builds still use the fast ssh-ng :2222 path via nix.buildMachines.
    # PREREQUISITE: GATEWAY_CLIENT_WEIGHT_BYTE=1 set on closure-build-gateway (done).
    (writeShellScriptBin "nix-sized" ''
      exec nix build \
        --eval-store auto \
        --store "unix:///run/closure-build-daemon/closure-build.sock" \
        "$@"
    '')

    #devenv


  ];

  programs = {
    direnv = {
      enable = true;
      nix-direnv.enable = true;
    };
  };

  nix = { 
    extraOptions = ''
        trusted-users = root jonas

        extra-substituters = https://devenv.cachix.org
        extra-trusted-public-keys = devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=
    '';
    settings.experimental-features = [ "nix-command" "flakes" "ca-derivations" ];
    settings.builders-use-substitutes = true;

  };

  hardware = {

    #firmware = [
    #  pkgs.unstable.ivsc-firmware
    #];

    /*
    pulseaudio.extraConfig = ''
      load-module module-alsa-sink   device=hw:0,0 channels=4
      load-module module-alsa-source device=hw:0,6 channels=4
    '';
    */

    #opengl = {
    #extraPackages = with pkgs; [ intel-ocl ];
    #};

  };






  # hyprlock's own fingerprint auth (auth:fingerprint in hyprlock.conf) talks
  # to fprintd directly. pam_fprintd in the same PAM stack claimed the same
  # sensor at the same time, so fprintd denied one side with "already
  # claimed"; that denial used to trigger the stale-claim reaper to restart
  # fprintd mid-verify, and hyprlock then hung after unlock (2026-09-11).
  # Disabling pam_fprintd here leaves hyprlock's native path as the only
  # claimant. The hyprlock-wrapper EXIT trap still restarts fprintd after
  # hyprlock exits.
  security.pam.services.hyprlock.fprintAuth = false;

  # Allow jonas to restart fprintd without a password (needed to clear stale
  # D-Bus claims after hyprlock exits without releasing the sensor).
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          action.lookup("unit") == "fprintd.service" &&
          action.lookup("verb") == "restart" &&
          subject.user == "jonas") {
        return polkit.Result.YES;
      }
    });
  '';

  security.tpm2 = {
    enable = true;
    # abrmd is a userspace TPM resource manager that competes with the
    # kernel's /dev/tpmrm0 for session slots. fafnir uses tpmrm0 by
    # default; running both yields "Esys called in bad sequence"
    # errors when they independently juggle TPM state. Disable abrmd
    # unless a legacy app explicitly needs a dbus/socket TCTI.
    abrmd.enable = false;
  };

  # fafnir: TPM-backed SSH agent + FIDO authenticator + age plugin.
  services.fafnir = {
    enable       = true;
    approval     = "fprintd";
    enableRsa    = true;
    rsaBits      = 2048;
    autoLockIdleSecs = 28800;
    powerledPath = "/sys/class/leds/tpacpi::power";
    # YubiKey OpenPGP keys are now reached via fafnir-openpgp's own
    # ssh-agent socket (scdaemon passthrough). fafnir's main agent
    # forwards to it, so SSH_AUTH_SOCK on the TPM agent gets both
    # the TPM identity and the card auth key.
    agentSockPaths = [ "$XDG_RUNTIME_DIR/fafnir/openpgp-ssh.sock" ];
    secretService.enable = true;
    # Opt-in LLM auto-approver (Venice.ai). Routine native sign/decrypt
    # requests skip the fingerprint prompt when they match a
    # human-approved precedent and the model concurs. Key lives in a
    # 0600 file outside the nix store.
    llmApprover = {
      enable     = true;
      apiKeyFile = "/home/jonas/.config/fafnir/venice.key";
      storePath  = "/home/jonas/.local/share/fafnir/approver/decisions.redb";
    };
  };

  # fafnir-keepassxc-bridge: native-messaging host for KeePassXC-Browser
  # (Chromium/Firefox), serving credentials out of fafnir's vault.
  services.fafnir-keepassxc-bridge = {
    enable = true;
    users  = [ "jonas" ];
  };

  # fafnir-wallet: Ledger-Nano-emulating Solana HD wallet daemon
  # (TPM-protected BIP39 seed, exposed as a UHID Ledger device).
  services.fafnir-wallet = {
    enable = true;
    users  = [ "jonas" ];
  };

  # fafnir-openpgp: gpg-agent replacement, TPM-backed. Mutually exclusive
  # with the upstream gpg-agent user service for the listed users.
  services.fafnir-openpgp = {
    enable          = true;
    users           = [ "jonas" ];
    pinentry        = pkgs.pinentry-qt;
    useSystemPcscd  = true;
  };

  # Expose YubiKey PIV slots through fafnir's PKCS#11 aggregator so the
  # fafnir-openpgp ssh-agent socket advertises PIV identities alongside
  # the OpenPGP card subkeys. OpenPGP is intentionally disabled here:
  # fafnir-openpgp already serves the OpenPGP applet via scdaemon, and
  # routing it through opensc-pkcs11 in parallel would cause PCSC
  # sharing violations on the YubiKey.
  services.fafnir.pkcs11.cards = {
    enable = true;
    openpgp.enable = false;
  };

  # Bind fafnir-openpgp to the XDG runtime gnupg socket path so gpg
  # tools find it at the standard location (gpgconf --list-dirs
  # agent-socket returns %t/gnupg/S.gpg-agent, not ~/.gnupg/S.gpg-agent).
  # Disable the competing gpg-agent sockets so they don't lock the
  # YubiKey first via their own scdaemon.
  systemd.user.services.fafnir-openpgp = {
    serviceConfig.ExecStartPre = lib.mkAfter
      [ "${pkgs.coreutils}/bin/mkdir -p %t/gnupg" ];
    serviceConfig.Environment  = lib.mkAfter [ "GNUPGHOME=%t/gnupg" ];
    unitConfig.Conflicts       = "gpg-agent.service";
  };
  systemd.user.sockets.gpg-agent.enable       = lib.mkForce false;
  systemd.user.sockets.gpg-agent-extra.enable = lib.mkForce false;

  # Raise per-user systemd default LimitNOFILE so transient units (e.g.
  # `systemd-run --user -p LimitNOFILE=...`) can be granted >524288 fds.
  # Required by magicblock-validator (RocksDB) for ER integration tests.
  systemd.user.extraConfig = ''
    DefaultLimitNOFILE=2097152
  '';

  # The module defaults to graphical-session.target, but WAYLAND_DISPLAY
  # is only imported into systemd's environment by the Hyprland exec-once
  # that starts hyprland-session.target. Binding to that target ensures
  # fafnir-prompt can connect to the compositor.
  systemd.user.services.fafnir = {
    unitConfig.After  = lib.mkForce [ "fafnir-openpgp.service" "hyprland-session.target" ];
    unitConfig.Wants  = lib.mkForce [ "fafnir-openpgp.service" ];
    unitConfig.PartOf = lib.mkForce [ "hyprland-session.target" ];
    wantedBy          = lib.mkForce [ "hyprland-session.target" ];
  };
  systemd.user.services.fafnir-passkey = {
    unitConfig.After  = lib.mkForce [ "fafnir.service" "hyprland-session.target" ];
    unitConfig.PartOf = lib.mkForce [ "hyprland-session.target" ];
    wantedBy          = lib.mkForce [ "hyprland-session.target" ];
  };

  # fafnir-secret-service owns org.freedesktop.secrets on jester,
  # so disable gnome-keyring's secrets component (default-enabled
  # in config/appearance.nix) to avoid the D-Bus name race.
  services.gnome.gnome-keyring.enable = lib.mkForce false;

  # gpg-agent SSH emulation has been retired — fafnir-openpgp serves
  # the YubiKey auth subkey directly on its own ssh-agent socket via
  # scdaemon passthrough, and fafnir's main agent forwards to it.
  programs.ssh.extraConfig = ''

    Host eu.nixbuild.net
      User root
      PubkeyAcceptedKeyTypes ssh-ed25519
      IdentitiesOnly yes
      IdentityAgent none
      IdentityFile /etc/ssh/ssh_host_ed25519_key
      ServerAliveInterval 60

    # closure.build remote builder via Fly.io gateway.
    # Port 2222 is encoded here because nix.buildMachines has no port field;
    # the alias "closure-build" is used as hostName in buildMachines.
    # Private key lives at /root/.ssh/closure_build_client (mode 0600, owner root),
    # outside the Nix store (world-readable). Key was placed there via:
    #   sudo install -m600 -o root -g root <repo>/closure_build_client /root/.ssh/closure_build_client
    # This must be re-run manually after a fresh checkout; it is NOT automated
    # via an activation script because the source path is outside the NixOS config.
    Host closure-build
      HostName closure-build-gateway.fly.dev
      Port 2222
      User builder
      IdentitiesOnly yes
      IdentityAgent none
      IdentityFile /root/.ssh/closure_build_client
      StrictHostKeyChecking yes
      # 15s: deployed builder sshd reaps idle sessions at ClientAliveInterval
      # 10s x3; client keepalives must arrive inside that 30s window or
      # inter-derivation stalls kill the session (Broken pipe mid-upload).
      ServerAliveInterval 15
      ServerAliveCountMax 5
      ConnectTimeout 30
  '';

  # Prevent nix-daemon crash on boot: Settings static initializer dereferences
  # HOME before nscd is ready. Setting HOME explicitly avoids the race.
  systemd.services.nix-daemon.environment.HOME = "/root";

  nix.distributedBuilds = true;
  nix.settings.max-jobs = 1; # 0 breaks preferLocalBuild=true derivations (e.g. /etc/issue)
  # Cap per-build parallelism for the local fallback path. The default
  # (cores = 0) means "all 12"; SCHED_IDLE keeps the CPU polite but 12-wide
  # compile memory can still push the session into MemoryHigh throttling.
  # Halved from 8 to reduce resource pressure; remote builders do the heavy lifting.
  nix.settings.cores = 4;
  # closure-build provisions a fresh Fly VM per build (cold start); keep this
  # generous so nix-daemon doesn't yank the SSH handshake before it's up.
  nix.settings.connect-timeout = 360;
  # Buffer for NAR downloads from remote builder / S3 cache.
  # 256 MiB: large enough to stream the biggest store paths (compiled APK,
  # BoringSSL .a) without hitting "download buffer is full", but small enough
  # to avoid the SIGABRT that 1 GiB caused (4 concurrent jobs × 1 GiB = 4 GiB
  # allocation → nix-daemon abort() on internal assertion with Nix 2.31.4).
  nix.settings.download-buffer-size = 128 * 1024 * 1024; # 128 MiB
  # Substituter parallelism, paired with download-buffer-size above: what
  # aborted the daemon before was the PRODUCT (1 GiB × 4 jobs = 4 GiB), so
  # doubling jobs while halving the buffer holds peak at the same 2 GiB that
  # 256 MiB × 8 has been running safely.
  #
  # Measured 2026-08-03 on this link, downloading real NARs from
  # cache.nixos.org: 6 concurrent → 30 Mbit/s, 24 concurrent → 36 Mbit/s.
  # Parallelism past ~6 buys little; the link itself tops out near 36 Mbit/s.
  # So this is a modest win, not a fix for slow rebuilds — an observed rebuild
  # averaged 11 Mbit/s because it interleaves CPU-bound NAR decompression and
  # actual builds, not because it ran out of download slots.
  nix.settings.max-substitution-jobs = 16;
  # Fall back to local build when a remote builder is unreachable instead of failing.
  nix.settings.fallback = true;
  # Self-heal a remote-builder upload-lock deadlock. A build dispatched to a
  # remote builder holds an exclusive flock on <builder>.upload-lock for its
  # whole upload phase; if that build's hook chain (nix __build-remote -> ssh ->
  # nix-tcp-proxy) wedges mid-upload (client SIGKILL'd by nix-build-retry,
  # cold-start blip, remote-side stdio worker stall), the lock is never
  # released and EVERY later build blocks forever at "waiting for the upload
  # lock to ssh-ng://..." — with max-jobs=0 there is no local escape.
  # max-silent-time bounds that: a build (incl. the stuck lock-holder) emitting
  # no log output for this long is aborted, which unwinds the hook and releases
  # the lock automatically. 1800s is generous enough for a legitimately silent
  # large-NAR upload / heavy compile (BoringSSL .a) yet recovers the deadlock
  # without manual `systemctl restart nix-daemon`. (2026-06-15 incident.)
  nix.settings.max-silent-time = 1800;
  # Larger TCP backoff on remote-build SSH so the link survives a
  # post-build-hook cache-push hiccup that briefly blocks the remote
  # nix-daemon write side.
  nix.settings.stalled-download-timeout = 300;
  # Expose /etc/gai.conf to the build sandbox so fixed-output fetchurl
  # derivations honor the host's prefer-ipv4-fallback dispatcher. Without
  # this, glibc inside the sandbox uses RFC 3484 default precedence (v6
  # preferred), and big VSIX/etc fetches over a slow IPv6 path crawl.
  nix.settings.extra-sandbox-paths = [ "/etc/gai.conf" ];
  # Tigris-backed paths first: the datapath goes through Tigris whenever it can
  # (gateway-off-datapath doctrine); cachix is the fallback.
  nix.settings.substituters = lib.mkAfter [
    # delta-proxy (patch-only local-base reconstruction): resolves base from local
    # nix store via nix-store --dump, fetches only the patch from Tigris — cheapest path.
    # Falls back to :8765 (full castore reconstruction) on cache miss.
    "http://localhost:8766"
    # cache-daemon: full castore/NAR reconstruction from Tigris. Fallback if no local base.
    "http://localhost:8765"
    # Prebuilt upstream Hyprland (jester runs the hyprwm/Hyprland flake build).
    "https://hyprland.cachix.org"
  ];

  # closure-build-daemon: client-side sizing daemon for the closure.build gateway.
  # Classifies build weight and forwards sizing hints to the gateway so it can
  # provision appropriately-sized VMs. The socket is exposed at
  # /run/closure-build-daemon/closure-build.sock for the nix-sized wrapper below.
  #
  # MANUAL STEP (run once after switch, requires sudo):
  #   sudo install -m600 -o root -g root <key-source> /root/.ssh/closure_build_client
  # (same key used for ssh-ng :2222; no new credential needed if already placed)
  #
  # NOTE: Set GATEWAY_CLIENT_WEIGHT_BYTE=1 on the closure-build-gateway Fly app
  # BEFORE using nix-sized, otherwise sizing sessions corrupt the gateway protocol.
  systemd.services.closure-build-daemon = {
    description = "closure.build client sizing daemon";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${nix-build-router.packages.x86_64-linux.client-daemon}/bin/closure-build-daemon";
      Restart = "always";
      RestartSec = "5s";
      RuntimeDirectory = "closure-build-daemon";
      # 0750 + group-owned socket (0660) so the unprivileged nix-sized wrapper
      # can connect. Trust boundary: members of `users` can dispatch remote
      # builds with root's gateway key — acceptable on this single-user box.
      RuntimeDirectoryMode = "0750";
      Group = "users";
      # Key delivered via systemd credentials: loaded as root BEFORE the mount
      # namespace is set up, then exposed read-only in $CREDENTIALS_DIRECTORY
      # (/run/credentials/<unit>). This survives ProtectHome=true, which masks
      # /root with a tmpfs and would otherwise hide the key (ReadOnlyPaths does
      # not reliably re-expose a single file under a ProtectHome tmpfs).
      LoadCredential = [ "clientkey:/root/.ssh/closure_build_client" ];
      Environment = [
        "CLOSURE_BUILD_CLIENT_KEY=/run/credentials/closure-build-daemon.service/clientkey"
        "CLOSURE_BUILD_SOCKET=/run/closure-build-daemon/closure-build.sock"
        "CLOSURE_BUILD_GATEWAY_HOST=closure-build-gateway.fly.dev"
        "CLOSURE_BUILD_GATEWAY_PORT=443"
        "CLIENT_DAEMON_SIZING=1"
        "CLIENT_DAEMON_BUILD_ID=1"
        "CLOSURE_BUILD_SOCKET_MODE=0660"
        "CLOSURE_BUILD_SOCKET_GROUP=users"
        "RUST_LOG=info"
      ];
      # Security profile matching cache-daemon / delta-proxy siblings.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ReadWritePaths = [ "/run/closure-build-daemon" ];
    };
  };

  # cache-daemon: local Nix binary-cache HTTP server reading castore from Tigris.
  # Secrets (AWS read creds) live in /etc/cache-daemon-env — root-only, not in git.
  # MANUAL STEP (run once after switch, requires sudo):
  #   sudo tee /etc/cache-daemon-env <<'EOF'
  #   AWS_ACCESS_KEY_ID=<TIGRIS_READ_KEY_ID>
  #   AWS_SECRET_ACCESS_KEY=<TIGRIS_READ_SECRET>
  #   EOF
  #   sudo chmod 600 /etc/cache-daemon-env
  systemd.services.cache-daemon = {
    description = "Nix binary-cache daemon (castore/Tigris)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${nix-build-router.packages.x86_64-linux.cache-daemon}/bin/cache-daemon";
      Restart = "always";
      RestartSec = "5s";
      EnvironmentFile = "/etc/cache-daemon-env";
      Environment = [
        "CACHE_BIND=127.0.0.1:8765"
        "AWS_BUCKET=closure-build-cache"
        "AWS_ENDPOINT_URL=https://fly.storage.tigris.dev"
        "AWS_REGION=auto"
      ];
      # Security hardening (no DynamicUser — needs EnvironmentFile as root)
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
  };
  # delta-proxy: patch-only local-base NAR reconstruction from Tigris deltas.
  # Reuses /etc/cache-daemon-env (same AWS read creds); no new secrets needed.
  systemd.services.delta-proxy = {
    description = "Nix delta-proxy (patch-only local-base reconstruction from Tigris)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    # nix-store must be on PATH: the base resolver shells out to `nix-store
    # --dump`; without it every request silently falls back to the full NAR.
    path = [ config.nix.package ];
    serviceConfig = {
      ExecStart = "${nix-build-router.packages.x86_64-linux.delta-proxy}/bin/delta-proxy";
      Restart = "always";
      RestartSec = "5s";
      EnvironmentFile = "/etc/cache-daemon-env";
      Environment = [
        "DELTA_PROXY_PORT=8766"
        "DELTA_PROXY_UPSTREAM=http://localhost:8765"
        "AWS_BUCKET=closure-build-cache"
        "AWS_ENDPOINT_URL=https://fly.storage.tigris.dev"
        "AWS_REGION=auto"
      ];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
  };

  nix.settings.trusted-public-keys = lib.mkAfter [
    "closure-build-cache-1:ZU3pD3lmJ+xSdqrPJOJOUsVYiaHRcWk+A7+fX3kjS8c="
    "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
  ];

  # Run the compositor (and matching xdg portal) from the upstream Hyprland
  # flake instead of nixpkgs-unstable. mkForce overrides the package set in the
  # shared config/i3_x11.nix module. hyprctl/hyprlock stay on nixpkgs-unstable
  # (only `hyprctl dispatch dpms on` is used; IPC skew is negligible) to avoid a
  # hyprctl binary collision in environment.systemPackages.
  programs.hyprland.package = lib.mkForce hyprland.packages.${pkgs.system}.hyprland;
  programs.hyprland.portalPackage = lib.mkForce hyprland.packages.${pkgs.system}.xdg-desktop-portal-hyprland;
  nix.buildMachines = [
    # nixbuild.net remote builder temporarily disabled; closure.build below is
    # the active remote builder.
    # {
    #   # nixbuild.net: managed remote builder, used as overflow/fallback.
    #   # speedFactor 1 (« closure.build's 10) so nix prefers closure.build and
    #   # only dispatches here when it's full or unreachable.
    #   # Auth: jester's host ed25519 key must be registered on the nixbuild.net
    #   # account (https://docs.nixbuild.net -> SSH keys). No "kvm"/"nixos-test"
    #   # feature: nixbuild.net doesn't run NixOS VM tests.
    #   hostName = "eu.nixbuild.net";
    #   sshUser = "root";
    #   sshKey = "/etc/ssh/ssh_host_ed25519_key";
    #   systems = [ "x86_64-linux" ];
    #   maxJobs = 100;
    #   speedFactor = 1;
    #   supportedFeatures = [ "big-parallel" "benchmark" ];
    #   protocol = "ssh-ng";
    # }
    {
      # closure.build remote builder via Fly.io gateway (ssh-ng over port 2222).
      # "closure-build" resolves via the Host alias in programs.ssh.extraConfig above.
      # The gateway provisions on-demand Fly performance-4x machines (x86_64-linux).
      # highest priority: prefer closure.build over nixbuild(1) when both are configured.
      # Trade-off: closure.build provisions a fresh VM per build (~9-17s cold start);
      # top priority means every eligible build pays that cold-start latency —
      # this is the user's explicit choice.
      hostName = "closure-build";
      sshUser = "builder";
      sshKey = "/root/.ssh/closure_build_client";
      systems = [ "x86_64-linux" ];
      # maxJobs = parallel nix-daemon connections jester opens to the gateway, and
      # EACH connection triggers one gateway provision. nix reuses each connection
      # across many derivations, so total provisions ≈ maxJobs, not the derivation
      # count. Must stay <= GATEWAY_MAX_CONCURRENT on closure-build-gateway (64),
      # or excess connections queue for slots.
      maxJobs = 64; # up to 64 parallel ephemeral builders (1 VM per job, scale-to-zero)
      speedFactor = 10; # highest priority: prefer closure.build over nixbuild(1)
      # kvm intentionally absent: the Fly builder VM does not expose /dev/kvm;
      # advertising it caused routing failures for kvm-requiring derivations.
      supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" ];
      protocol = "ssh-ng";
    }
  ];
  programs.ssh.knownHosts."closure-build-gateway" = {
    # Host key for closure-build-gateway.fly.dev:2222 (closure.build Fly.io gateway).
    # Obtained via: ssh-keyscan -p 2222 closure-build-gateway.fly.dev
    hostNames = [ "[closure-build-gateway.fly.dev]:2222" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILiy2Sjb0ZBEXv9tS6LLJ59IZ6bhpKcXw9RB522nC5yJ";
  };
  programs.ssh.knownHosts.nixbuild = {
    hostNames = [ "eu.nixbuild.net" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPIQCZc54poJ8vqawd8TraNryQeJnvH1eLpIDgbiqymM";
  };

  # Debounce for MX Anywhere 3S failing switch handled by mx-debounce systemd service.

  # Weekly cleanup of stale Rust build artifacts in ~/workspace.
  # cargo-sweep --time 30 removes artifacts unused for 30 days; entire
  # target/ dirs whose parent Cargo.toml hasn't been built in 30 days are
  # wiped wholesale. Stays out of .git, node_modules, .direnv, result.
  systemd.user.services.cargo-sweep-workspace = {
    description = "Sweep stale Rust build artifacts in ~/workspace";
    serviceConfig = {
      Type = "oneshot";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
    path = [ pkgs.cargo-sweep pkgs.coreutils pkgs.findutils ];
    script = ''
      set -u
      ws="$HOME/workspace"
      [ -d "$ws" ] || exit 0
      # Wipe whole target/ dirs older than 30 days (sibling Cargo.toml).
      find "$ws" -type d -name target -prune \
        \( -path '*/node_modules/*' -o -path '*/.git/*' \) -prune -o \
        -type d -name target -prune -print0 2>/dev/null \
      | while IFS= read -r -d "" t; do
          [ -f "$(dirname "$t")/Cargo.toml" ] || continue
          if [ -z "$(find "$t" -newermt '30 days ago' -print -quit 2>/dev/null)" ]; then
            rm -rf "$t"
          fi
        done
      # Sweep stale artifacts inside remaining target/ dirs.
      cargo sweep --recursive --time 30 "$ws" || true
    '';
  };
  systemd.user.timers.cargo-sweep-workspace = {
    description = "Weekly cargo-sweep of ~/workspace";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
  };
}
