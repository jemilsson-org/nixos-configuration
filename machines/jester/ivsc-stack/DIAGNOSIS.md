# IVSC / OV9234 IR camera on jester — diagnosis

Status as of 2026-08-21 (branch `fix/ljca-enum`).

## What works
- RGB camera (ov2740, `\_SB.PC00.LNK1`): streams fine via libcamera.
- IR sensor (ov9234, `\_SB.PC00.LNK0`): enumerates as a libcamera camera and links into
  the media graph, but has never streamed, because its IVSC transport never comes up
  (below).

## Root cause (proven via live ACPI read, not inferred)
The IVSC transport is ACPI device `INTC1009` (`\_SB.PC00.SPI1.SPFD`), matched in-tree by
`vsc-tp` (`mei-vsc.ko`; its ACPI match table already lists INTC1009). `INTC1009._CRS`
returns one of two `SpiSerialBus` descriptors, gated on GNVS byte `CVFS`:

- `CVFS == 2`: routes to LJCA (`CUPN == 8` selects `\_SB.PC00.XHCI.RHUB.HS08.VSPI`, the
  LJCA USB-SPI bridge's virtual SPI port).
- `CVFS != 2`: routes to native `\_SB.PC00.SPI1`, PCI `00:1e.3` (SerialIO GSPI1).

Live values read on this machine: `CVFS = 0x0`, `CUPN = 0x8`. So `_CRS` resolves to
native SPI1 — but SPI1 (`00:1e.3`) is **function-disabled in firmware** (`_STA = 0x08`,
absent from PCI config space, no `lspci` entry) and SMM-locked: the `SM01` NVS mode-select
byte that would enable it is off, and runtime NVS writes to `SM01` do not un-hide the PCI
function (confirmed by live testing on branch `fix/ov9234-ivsc`; not re-tested here). No
Linux-runtime fix creates a working native SPI1: there is no host controller to attach
INTC1009 to on that path.

The LJCA path, by contrast, is a real, present, working USB-SPI bridge (`usb_ljca` /
`spi_ljca` already provide `spi0`; a separate device `spi-LATT2021:00`, the Lattice
firmware-update client `LFUD`, already sits on `spi0` cs0 — that device is unrelated to
the camera transport and was a red herring in an earlier version of this document). Since
`CUPN == 8` already selects the correct LJCA route in `_CRS`, the only missing piece is
`CVFS`: if it reads 2 at the moment `INTC1009._CRS` is evaluated (SPI bus enumeration
time), the kernel builds the `spi_device` on `spi0` itself and `vsc-tp` binds it through
its normal ACPI match — no synthesized `spi_device`, no force-bind, no out-of-tree SPI
transport driver needed.

### Earlier theories, corrected
- "Enable GSPI1 via a hidden `PchSetup` UEFI variable" (previous revision of this file):
  targets a PCI function that is SMM-locked; abandoned, not attempted live.
- "Force-bind `vsc-tp` to `spi-LATT2021:00`" (`vsc-tp-bind.nix`, commit `ed555d04`):
  wrong device. `LATT2021`/`LFUD` is the Lattice firmware-update client, not the IVSC
  transport, and is not in `vsc-tp`'s ACPI match table; forcing the bind returns `-ENODEV`
  (the kernel enforces the match table on manual `bind`, confirmed live). Removed by this
  fix.

## The fix: early CVFS poke
`CVFS` lives in GNVS (an ACPI `OperationRegion(SystemMemory)` the firmware fills at boot),
confirmed at physical base `0x5A1A3000`, region length `0xD09`, `CVFS` at offset `0xB79`,
`CUPN` at offset `0xB7A`. `STRICT_DEVMEM` blocks a userspace `/dev/mem` write, so this
needs a kernel module.

`ivsc-stack/ivsc-cvfs-poke/` is an out-of-tree module that `ioremap()`s the GNVS page,
verifies the `CUPN == 0x08` signature before touching anything (refuses to write on a
mismatch, so a firmware update that relocates GNVS fails closed instead of corrupting an
unrelated region), then writes `CVFS = 2`, verifies the readback, and logs before/after
values. It is loaded via `boot.initrd.kernelModules`, before `usb_ljca`/`mei_vsc` probe,
so `CVFS` already reads 2 the first time `INTC1009._CRS` is evaluated during SPI bus
enumeration. See `ivsc-cvfs-poke/ivsc_cvfs_poke.c` for the full implementation and the
readback/signature guard.

Native SPI1 being firmware-disabled means it cannot win a first-probe race regardless of
module ordering, so no driver blacklist is needed; noted as a re-check item in
`camera.nix` in case a firmware update ever re-enables that function.

### Still needs live verification (reboot-gated, not done in this fix)
- `dmesg | grep ivsc_cvfs_poke` shows the CVFS write and readback succeeding.
- `INTC1009` enumerates a `spi_device` on `spi0` (not `00:1e.3`).
- `vsc-tp` binds it (`/sys/bus/spi/devices/spi-INTC1009:00/driver` -> `vsc-tp`).
- `mei_vsc`/`ivsc_ace`/`ivsc_csi` come up and the IR camera streams end to end
  (libcamera capture and/or direct V4L2 `VIDIOC_STREAMON` succeeds on `/dev/video8`).
- If the GNVS page turns out to be write-protected (module logs `-EIO` from the readback
  check), the fallback is an SSDT override of `INTC1009._CRS` — a separate task.

## vsc-tp probe: three -EINVAL blockers under CVFS=2, one is a hardware wall

With CVFS=2 confirmed working (`spi-INTC1009:00` enumerates on `spi0` and `vsc-tp`
matches it), `vsc_tp_probe()` still fails, in three layers, live-tested by
`rmmod`/`insmod` of an out-of-tree `mei_vsc_hw_patched` module
(`ivsc-stack/vsc-tp-patched/`) that is the unmodified kernel 7.1.7
`drivers/misc/mei/{vsc-tp,vsc-fw-loader}.c` with targeted fixes:

1. **Wake IRQ trigger type (`-EINVAL` at `request_threaded_irq`)**: upstream requests
   `IRQF_TRIGGER_FALLING`. The wake GPIO (`\_SB.GPI0` pin 23, SML1ALERTB) is a
   PADCFG-locked, ACPI-owned pad; intel-pinctrl refuses to reprogram a locked pad's
   trigger type. Fix: request `IRQF_TRIGGER_NONE | IRQF_ONESHOT` instead, so genirq
   skips `__irq_set_trigger()`/`intel_gpio_irq_type()`. This avoids that specific
   `-EINVAL` but is necessary, not sufficient — see point 3.

2. **Missing `wakeupfw` ACPI GPIO resource (`-EINVAL` at `devm_gpiod_get`)**: verified
   live by enumerating every ACPI GPIO index on `spi-INTC1009:00` (added debug code,
   since removed) — indices 0-2 (`wakeuphost`, `wakeuphostint`, `resetfw`) exist, index 3
   (`wakeupfw`) does not. Decoding the DSDT's `INTC1009._CRS` Method (`/tmp/DSDT.dsl` on
   jester, or `nix run nixpkgs#acpica-tools -- acpidump -b` + `iasl -d`) confirms this
   byte-for-byte: the `CVFS==2` branch returns `CBUF+VGBn+VSBn` (3 GPIO resources: 2 from
   `CBUF`, common to both branches, 1 from the LJCA `VGPO` expander via `VGBn`), while the
   `CVFS!=2` (native SPI1) branch returns `CBUF+GBUF+SBUF`, where `GBUF` carries 2 GpioIo
   resources (indices 2 and 3: `resetfw` at native `\_SB.GPI0` pin 357, `wakeupfw` at pin
   14) that the LJCA branch simply omits — firmware never wired `wakeupfw` through the
   LJCA GPIO expander and forgot to keep exposing its native pin in the rerouted `_CRS`.
   Fix: when `devm_gpiod_get(..., "wakeupfw", ...)` returns `-EINVAL`, fall back to
   requesting native pin 14 directly from the `\_SB.GPI0` gpiochip (label
   `INTC1055:00`) via `gpio_device_find_by_label()` + `devm_gpio_request_one()`,
   bypassing the incomplete ACPI resource list. **Verified live: this fix works** —
   `vsc_tp_probe()` gets past the `wakeupfw` lookup.

3. **Wake IRQ pad is hardware-locked OUTPUT-ONLY (`-EIO` at `request_threaded_irq`,
   genuine wall)**: with both fixes above applied, `request_threaded_irq()` on pin 23
   now fails differently:
   ```
   gpio gpiochip0: (INTC1055:00): gpiochip_lock_as_irq: tried to flag a GPIO set as output for IRQ
   gpio gpiochip0: (INTC1055:00): unable to lock HW IRQ 23 for IRQ
   genirq: Failed to request resources for spi-INTC1009:00 (irq 204) on irqchip intel-gpio
   ```
   `gpiochip_lock_as_irq()` reads intel-pinctrl's live `get_direction()` for pin 23, not
   any Linux-side flag either fix touched. Live `pinconf-pins` shows `PADCFG0 =
   0x44000200`: bit9 (`GPIORXDIS`) = 1, bit8 (`GPIOTXDIS`) = 0 — the pad's **input
   receiver is hardware-disabled**, output driver enabled. This corrects the original
   diagnosis at the top of this section (and in earlier commits), which assumed pin 23
   was a locked *input* with just the wrong trigger type; it is actually locked as an
   **output-only** pad. No trigger-type argument can make an output-only pad serve as an
   interrupt source. The pad is `HOSTSW_OWN=ACPI`-locked, so pinctrl refuses runtime
   reprogramming of direction for the same reason it refuses trigger-type changes.
   Advisor-confirmed (three independent lines of evidence: physical `PADCFG0` state,
   firmware ownership lock, and the `CVFS==2` branch's own omission of a `wakeupfw`
   resource suggesting firmware doesn't expect this pin to matter under LJCA routing):
   this is a genuine firmware/hardware wall, not fixable by any kernel-side or live
   `rmmod`/`insmod` change. The only paths that could clear it — a BIOS update, or an
   SSDT override of the pad's boot-time configuration — both require a reboot and are out
   of today's scope (no EFI vars, no BIOS changes).

**Net effect**: fixes 1 and 2 are real, necessary, and verified live; fix 3 does not
exist within today's constraints, so `vsc_tp_probe()` does not currently succeed and no
IR frames were captured this session. Fixes 1 and 2 are committed regardless — they are
correct, load-bearing fixes for real bugs this platform's CVFS=2 routing exposes, and
whichever SSDT/BIOS fix eventually clears the pin-23 wall will need them both anyway.

## CVF Support default resolution (2026-08-22, corrected)

Extracted from Lenovo firmware N3XET67W v1.42 (same formset/varstore/offset as
the v1.41 target; ifrextractor-rs on the SPI capsule). CVF Support QuestionId
0x539, VarStore Setup (GUID EC87D643-...), VarOffset 0x9B9:

    OneOfOption "USB Bridge" Value: 2, Default, MfgDefault
    Default DefaultId: 0x0  ->  Uint64 Value: 0x0

An explicit EFI_IFR_DEFAULT opcode overrides DefaultId 0x0 to 0, which wins over
the option's inline Default flag (UEFI HII rule). Result:
- DefaultId 0x0 (Standard / F9 "Load Setup Defaults"): 0 = Disabled
- DefaultId 0x1 (Manufacturing / not reachable via F9): 2 = USB Bridge

Consequences:
- The live value 0x00 on jester IS the standard default; it did not drift.
- F9 Load Setup Defaults resolves CVF Support to Disabled -> will NOT enable IVSC.
- Units ship working because Lenovo applies MANUFACTURING defaults on the line
  (USB Bridge = 2). Any later Setup-defaults re-init (BIOS update, CMOS event)
  flips it to Disabled with no visible control to restore it.
- Only fixes: external SPI-flash write of 0x9B9=0x02, or Load Manufacturing
  Defaults (not exposed by F9 / visible menu on this platform).
- SPI1 Controller (QuestionId 0xD81, PchSetup): only DefaultId 0x0 declared = 0.
