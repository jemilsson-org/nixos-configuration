# Sets GNVS byte CVFS=2 before SPI enumeration, so the ACPI INTC1009
# (IVSC transport) _CRS routes to the LJCA USB-SPI bridge instead of the
# firmware-disabled native SPI1. See ../DIAGNOSIS.md.
{ lib, stdenv, kernel }:

stdenv.mkDerivation {
  pname = "ivsc_cvfs_poke";
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
    install -Dm444 ivsc_cvfs_poke.ko \
      $out/lib/modules/${kernel.modDirVersion}/extra/ivsc_cvfs_poke.ko
    runHook postInstall
  '';

  meta = {
    description = "Early GNVS CVFS=2 poke to route IVSC transport (INTC1009) to LJCA SPI";
    license = lib.licenses.gpl2Only;
    platforms = [ "x86_64-linux" ];
  };
}
