# Out-of-tree replacement for the in-tree mei_vsc_hw module.
#
# The wake GPIO (\_SB.GPI0 pin 23, SML1ALERTB) is a PADCFG-locked, ACPI-owned
# native SoC pad locked OUTPUT-ONLY with its input receiver disabled
# (PADCFG0=0x44000200, GPIORXDIS=1). It cannot be an IRQ source (genirq's
# gpiochip_lock_as_irq rejects it: "Failed to request resources ... irqchip
# intel-gpio", probe -EIO) and cannot even be read for level. This module
# rewrites drivers/misc/mei/{vsc-tp,vsc-fw-loader}.c for kernel 7.1.7 to drop
# the wake IRQ entirely and drive the transport by SPI polling instead:
# fixed prepare delays on the ROM stage, and the existing packet-SYNC (0x31)
# marker scan on the runtime stage. Delays/clock are module params (poll_*).
#
# Spike result (see ../DIAGNOSIS.md): polling removes the IRQ dependency and
# vsc-tp probe + fw-loader + mei_vsc bind all proceed, but the VSC ROM does
# not answer the SPI protocol on the LJCA USB-SPI path (spi-INTC1009:00):
# every ROM response is idle-line only (0xff floating then 0x00), never the
# ROM magic 0x49505343 "IPSC", at 1/9 MHz alike. So the camera still cannot
# stream; that blocker is beneath the interrupt question, not solved by it.
{ lib, stdenv, kernel }:

stdenv.mkDerivation {
  pname = "mei_vsc_hw_patched";
  version = "0.1-${kernel.version}";

  src = ./.;

  hardeningDisable = [ "pic" ];
  nativeBuildInputs = kernel.moduleBuildDependencies;

  buildPhase = ''
    runHook preBuild
    make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
      M=$PWD modules
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm444 mei_vsc_hw_patched.ko \
      $out/lib/modules/${kernel.modDirVersion}/extra/mei_vsc_hw_patched.ko
    runHook postInstall
  '';

  meta = {
    description = "vsc-tp with unlocked-pad-safe IRQ trigger, replacing in-tree mei_vsc_hw";
    license = lib.licenses.gpl2Only;
    platforms = [ "x86_64-linux" ];
  };
}
