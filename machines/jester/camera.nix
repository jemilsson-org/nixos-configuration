{ config, inputs, lib, pkgs, modulesPath, ... }:

let
  # Recompile only the IPA module with a smaller AGC step size (3.3% vs 10%)
  # to eliminate the gain oscillation loop on the OV2740 sensor.
  # WirePlumber's libcamera.so accepts this IPA: both are signed with the
  # same static nixpkgs private key, so signature verification passes.
  #
  # TODO(camera color): the OV2740 runs on libcamera's UNCALIBRATED soft-ISP
  # tuning (no ov2740.yaml -> uncalibrated.yaml, which has NO CCM). AWB is
  # grey-world and neutralises the white point correctly, but with no colour
  # correction matrix the raw sensor primaries are never mapped to sRGB, so
  # non-neutral regions carry a green/desaturated cast ("washed out"). The
  # contrast-default patch mitigates the flatness; the green cast needs a
  # tuned CCM (enable the `Ccm:` block in a proper ov2740 tuning yaml). That
  # requires colour-target calibration for this sensor; not a code guess.
  # Root cause verified against src/ipa/simple/algorithms/{awb,adjust,blc}.cpp.
  libcamera-patched = pkgs.libcamera.overrideAttrs (old: {
    patches = (old.patches or []) ++ [
      ./libcamera-agc-step-size.patch
      ./libcamera-contrast-default.patch
      # 10-bit mono (Y10 / Y10P) input for the soft ISP: the OV9234 IR
      # sensor only produces Y10_1X10, which debayer_cpu rejected
      # ("Unsupported input format R10"). Adds an R10/R10_CSI2P -> R8
      # line copy and reuses the existing bayer stats path so AGC works.
      ./libcamera-mono-r10.patch
    ];
    # Sensor tuning file: enables the Ccm block (generic saturation-boost
    # matrix, see ov2740-tuning.yaml) instead of the CCM-less uncalibrated
    # fallback. Note: the soft-ISP Ccm costs extra CPU per frame.
    postInstall = (old.postInstall or "") + ''
      cp ${./ov2740-tuning.yaml} $out/share/libcamera/ipa/simple/ov2740.yaml
    '';
  });

  # Refits the Ccm block above from a photographed ColorChecker; see
  # webcam-calibrate.py for the method.
  webcamCalibrate = pkgs.callPackage ./webcam-calibrate.nix { };
in
{
  # Use latest kernel from unstable for xe driver DP-MST fixes (needs 6.21+)
  boot.kernelPackages = pkgs.unstable.linuxPackages_latest;

  # Intel IPU6 MIPI camera (OV2740 sensor, Raptor Lake).
  # kernel ipu6-isys -> libcamera "simple" pipeline -> wireplumber -> apps.
  boot.extraModulePackages = with config.boot.kernelPackages; [
    ipu6-drivers
    # IR sensor (ACPI OVTI9234, \_SB_.PC00.LNK0, behind LJCA/IVSC): no
    # upstream driver exists; local port of mainline ov9734.c. Built via
    # config.boot.kernelPackages so it targets the PATCHED kernel below.
    (callPackage ./ov9234 { })
    # ipu-bridge only links sensors from its static HID table; shadow the
    # in-tree module with one carrying the OVTI9234 entry (updates/ wins
    # in depmod order) instead of patching the kernel, since the remote
    # builder cannot fit kernel rebuilds.
    (callPackage ./ipu-bridge-shadow { })
    # The in-kernel IVSC stack (vsc-tp/platform-vsc/ivsc-ace/ivsc-csi) is
    # complete on 7.x but never probes here: no spi_device is created for
    # \_SB.PC00.SPI1.SPFD (INTC1009) on the LJCA SPI controller, so the VSC
    # firmware is never loaded and CSI-2 lane ownership is never handed to
    # the IPU6. This registers that one missing device.
    (callPackage ./ivsc-stack { })
  ];
  # Load order at runtime: vsc-spi-bind creates the SPI device, vsc-tp
  # (mei-vsc-hw) probes it and spawns the intel_vsc platform device, mei_vsc
  # brings up the MEI link, then the ivsc_ace/ivsc_csi MEI clients appear and
  # ivsc_csi joins the media graph in front of ov9234. Only vsc-spi-bind needs
  # forcing; the rest autoload on their bus/ACPI aliases once it succeeds.
  # Keep the explicit list anyway: this machine has shown no autoload for them.
  boot.kernelModules = [ "spi_ljca" "vsc_spi_bind" "mei_vsc" "ivsc_ace" "ivsc_csi" ];
  hardware.firmware = with pkgs; [ ipu6-camera-bins ivsc-firmware ];

  environment.systemPackages = with pkgs; [ libcamera ] ++ [ webcamCalibrate ];

  users.users.jonas.extraGroups = [ "video" ];

  # Open IPU6 media pipeline nodes to the video group so wireplumber/libcamera
  # can enumerate them. Numbered 100- to run after 99-local.rules.
  services.udev.packages = [
    (pkgs.writeTextFile {
      name = "ipu6-camera-access-rules";
      destination = "/lib/udev/rules.d/100-ipu6-camera-access.rules";
      text = ''
        SUBSYSTEM=="intel-ipu6-psys", MODE="0660", GROUP="video"
        SUBSYSTEM=="media", DRIVERS=="intel-ipu6", GROUP="video", MODE="0660", TAG+="uaccess"
        SUBSYSTEM=="video4linux", DRIVERS=="intel-ipu6", GROUP="video", MODE="0660", TAG+="uaccess"
      '';
    })
  ];

  # Allow WirePlumber's embedded libcamera to open /dev/media0 (char major 243).
  # DevicePolicy=auto in the service unit denies devices not in the cgroup
  # allow-list; char-media is not included by default.
  systemd.user.services.wireplumber.serviceConfig.DeviceAllow = [
    "char-media rw"
  ];

  # Load the patched IPA (smaller AGC step) instead of the default one.
  # LIBCAMERA_IPA_MODULE_PATH is searched before the built-in path, so our
  # ipa_soft_simple.so wins without rebuilding WirePlumber.
  systemd.user.services.wireplumber.environment = {
    LIBCAMERA_IPA_MODULE_PATH = "${libcamera-patched}/lib/libcamera/ipa";
    # Tuning files are searched in LIBCAMERA_IPA_CONFIG_PATH (or the linked
    # libcamera's own share dir), NOT in the module path above, so point it
    # at the patched package for ov2740.yaml to be found.
    LIBCAMERA_IPA_CONFIG_PATH = "${libcamera-patched}/share/libcamera/ipa";
  };

  # Thunderbolt: prevent runtime-suspend which drops DP tunnels
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{power/control}="on"
  '';
}
