# Decisions

Settled rulings so compaction summaries carry a pointer, not prose.

## jester: IR camera / Windows Hello unreachable in software (2026-08-22)

The OV9234 IR sensor (Windows Hello) cannot stream under Linux on this unit, and
the block is firmware, not driver. Full investigation record lives on branch
`fix/ljca-enum` at `machines/jester/ivsc-stack/DIAGNOSIS.md` (kept unmerged: it
also deletes `presence-lock.nix` and disables `autoUpgrade`, both test-only).

Root cause (proven by ifrextractor-rs on Lenovo N3XET67W v1.42 SPI capsule): the
IVSC master enable "CVF Support" (UEFI Setup var, GUID
EC87D643-EBA4-4BB5-A1E5-3F3E36B20DA9, QuestionId 0x539, VarOffset 0x9B9) has a
default contradiction. The USB Bridge option (value 2) carries inline
Default+MfgDefault flags, but an explicit EFI_IFR_DEFAULT opcode overrides
DefaultId 0x0 to 0. So the STANDARD default (what F9 "Load Setup Defaults"
applies) is Disabled(0); only the MANUFACTURING default is USB Bridge(2).
jester's live value 0x00 IS the standard default. F9 does NOT enable the camera.
Units ship working because Lenovo applies manufacturing defaults on the line; a
later Setup-defaults re-init (BIOS update / CMOS event) flips CVF Support to
Disabled, and the question is not in Lenovo's visible F1 menu. The Setup var is
SMM-write-protected from the OS (EROFS).

Remedies (both hardware, neither a BIOS-menu action):
- External SPI-flash programmer (CH341A) writing Setup:0x9B9 = 0x02.
- USB IR camera + Howdy, sidestepping the built-in sensor.

RGB camera (OV2740) works and is unaffected.

### RU.efi-class pre-boot write ruled out (2026-08-22)

Tested setup_var.efi from the pre-boot DXE context via a systemd-boot menu
entry (branch test/cvf-setupvar). Two boots: `setup_var.efi Setup:0x9B9=0x02`
did not change the value; efivars still reads 0x00 after each. Only one "Setup"
variable exists with GUID EC87D643-... (others are SetupHotKey / SetupMode), so
the write hit the correct target and was rejected. The SPI flash write-lock is
hardware-enforced (BIOS_CNTL/PR registers), not a runtime SetVariable filter, so
no OS- or shell-context tool can flip the byte. External SPI programmer is the
only remaining route; user declined it as too risky. Software path CLOSED.

### Windows' own USB-SPI path tested and confirmed gated (2026-08-22)

Dissected the Lenovo Windows driver (mipi_camera_driver.exe): Windows drives the
IR camera NOT over native SPI1/INTC1009/mei_vsc, but over the LJCA USB bridge
(CvfUsbBridge -> UsbSpi -> spbkmdfdriver) doing a raw SPI_READ_ID against the
Lattice FPGA LATT2021 on the VSPI controller (INTC1098), CS 0, 8 MHz. Every
piece exists on Linux (spi1 = live LJCA SPI master; VSPI/LATT2021 enumerated;
LJCA i2c devices at 0x30/0x63 respond), so this looked like a missing-driver
problem, not a firmware lock.

Tested it directly: built a stub kernel module to attach spidev to spi1 CS0 and
replayed the Windows handshake (27 transfers: modes 0/3, 1/8 MHz, opcodes
0x9F/0xE0/0xC0). ALL returned 0xFF, clean, no timeouts = FPGA SPI endpoint
silent/unpowered. The bus works; the FPGA does not answer. So Windows' exact
path also fails on this unit with CVF Support disabled - the gate is at the
hardware/power level, below any OS, exactly what CVF Support controls. This
tests the Windows path down to the silicon and confirms CVF Support=Disabled is
a real hardware gate, not a Linux driver gap. Software path CLOSED for good;
only an external SPI programmer (write Setup:0x9B9=0x02) can enable it.

### FPGA is alive on I2C but imaging path gated; GPIO bring-up NO-GO (2026-08-22)

The Lattice FPGA LATT2021 (IVSC/VSC) is NOT dead. Over its LFUD I2C channel
(bus i2c-13, addr 0x30, ACPI \_SB.PC00.XHCI.RHUB.HS08.LFUD) it returns stable
register data: reg0=0x00, reg1=0x27, reg2=0xd4 (likely device/version ID). So
the chip is powered and its control/update interface responds.

But its SPI/imaging (VSC CSI-mux) function stays silent (SPI READ_ID all 0xFF).
Drove its 5 control GPIOs (gpiochip1/INTC1096 lines 3,11,16,19,27) through
all-high, all-low, per-line reset pulses, and synchronized toggle: I2C register
values never moved off baseline and no VSC/CSI/ov9234 dmesg activity appeared.
So the GPIO lines are not the imaging enable, and GPIO bring-up is NO-GO.

Conclusion: the imaging pipeline is armed by the stock IVSC firmware bring-up
sequence, which never runs because CVF Support is Disabled. The FPGA being
I2C-reachable does not contradict the firmware gate; the control channel is
always available, the imaging enable is what's gated. Remaining theoretical
camera path = reverse-engineer the LFUD/VSC bring-up (firmware load + CSI enable)
over I2C, reimplementing Intel's CvfUsbBridge against signed firmware; large RE
effort, uncertain (CSI enable may itself be CVF-gated). The live LFUD channel is,
separately, the interface for any future "talk to / update the FPGA" work.

### Windows FPGA bring-up replicated on Linux and proven ineffective; SMM_BWP confirmed (2026-08-22)

Deep RE of Windows spbkmdfdriver.sys resolved the exact FPGA (LATT2021) bring-up
and we replicated it on live hardware with root. Two solve-paths, both now closed
with register-level evidence:

1. DIRECT CVF-BYTE WRITE via flash: BIOS_CNTL (00:1f.5 cfg 0xDC) = 0xAA => BLE=1,
   SMM_BWP=1. The BIOS/NVRAM flash region is writable only from SMM; the OS cannot
   write it even as root. flashrom -p internal also blocked by kernel lockdown
   ("Cannot map ecam region"). So both SetVariable (SMM-filtered) AND raw flash
   (SMM_BWP) are closed. Confirms external SPI programmer is the only flash route.

2. FPGA MODE-SWITCH over I2C (the Windows path): the Lattice chip answers on
   i2c-13/0x30 but is stuck PRE-INIT: reg0x00=0x00 (driver expects family ID in
   {0xFC,0xF6,0xF1}), reg0x0F=0x00 (ready bit clear), regs 0x01=0x27/0x02=0xd4/
   0x0d=0x12 are its always-on stub. Windows' FM->APP switch is `write reg 0x0E=0x01`;
   we issued it (root, i2cset) - ACKed but did NOT latch (0x0E stays 0x00), no
   effect. Per the driver's own logic it won't switch unless the chip is in
   FM-ready state first. The driver's reset (fcn.1400058f0) is NOT a physical reset
   or register write - it's an SPB connection-level control IOCTL (0x41814,
   payload {0xFF,0x00}) handled by the I2C host-controller driver, not replayable
   as i2cset, and won't wake an un-initialised chip. The driver has ZERO GPIO/ACPI
   code. GPIO toggling (VGPO lines 3/11/16/19/27) had no effect. The IVSC ACPI
   nodes (VGPO/VIC0/VSPI/LFUD under HS08) are bare Device nodes with NO
   _PS0/_PS3/_RST/_INI/_DSM/power-resource methods - no ACPI power-on/reset lever.

Conclusion: the FPGA's imaging bring-up (power/reset/firmware-init that would move
reg0x00 to a family ID and arm the SPI/CSI path) is performed only by the firmware
IVSC init, which never runs because CVF Support=Disabled. Every OS-reachable lever
(I2C mode-switch, SPB reset IOCTL, GPIO, ACPI methods, flash write) is downstream
of that gate and ineffective. SOFTWARE SOLVE IMPOSSIBLE on this unit, proven at the
register level by replicating Windows' exact sequence. The ONLY fix remains an
external SPI programmer writing Setup:0x9B9=0x02 (which re-enables the firmware
IVSC init, after which all the validated OS machinery would work), or a USB IR
camera + Howdy.

### FPGA bring-up: full Windows I2C sequence replayed on hardware, ineffective; SPI stub CET-crashed (2026-08-23)

Ran the complete Windows FM->APP bring-up on live hardware (root): I2C write
reg 0x0E=0x01 to LATT2021 @ i2c-13/0x30, single and full 3-round retry loop with
up to 100-200 polls of reg 0x00 for a family ID (0xFC/0xF6/0xF1). Result:
reg 0x0E never latches (stays 0x00), reg 0x00 never moves from 0x00, reg 0x0F
stays 0x00. The chip rejects the mode-switch outright - it is held PRE-INIT.
Version block 0x54-0x5F reads all-zero, confirming its config logic isn't loaded.

The only untried fragment was the interleaved dummy 0xFF SPI write. Instantiating
spidev on the LJCA spi1 (VSPI/INTC1098, no ACPI spi slave) needed an out-of-tree
stub; the stub resolved the unexported spi_controller_class via a kprobe on
kallsyms_lookup_name, which triggered a CET control-protection oops on load
(exc_control_protection, insmod exited with irqs disabled). Kernel survived but
tainted; spistub wedged (rmmod fails, needs reboot). Not pursued further: the
technique is fragile/rootkit-style, and the SPI dummy is only a poke before
re-issuing the already-ignored I2C write.

### Lenovo authenticated-SMI (thinklmi) path does NOT expose CVF Support (2026-08-24)

The one OS-side NVRAM write route not blocked by SMM_BWP is Lenovo's own
authenticated SMI handler (Linux `thinklmi` / firmware-attributes), proven
writable on this unit earlier (we flipped EnhancedWindowsBiometricSecurity
through it). Tested whether the IVSC/CVF enable is reachable that way.

Read all thinklmi attributes (root). No "CVF Support" attribute exists; the
hidden Intel-Advanced-formset var (QuestionId 0x539, 0x9B9) is not enumerated by
Lenovo WMI, so SetBiosSetting cannot target it. The two attributes that could
plausibly gate the IVSC are ALREADY enabled while the camera is dead:
UserPresenceSensing=Enable, IntegratedCameraAccess=Enable (also
ThinkShieldPasswordlessPowerOnAuthentication=Enable;
EnhancedWindowsBiometricSecurity=Disable). So neither controls the imaging init,
and the authenticated-SMI path is not a lever for CVF Support. Avenue CLOSED.

Note on the "factory machine" question: UPS/camera-access at Enable are
consistent with a factory config, yet CVF Support sits at the STANDARD default
(Disabled), not the MANUFACTURING default (USB Bridge). So on this unit the
firmware boots the IVSC gate off; Windows Hello would fail here identically
(proven separately by replaying Windows' own driver sequence on the chip). The
external SPI programmer (Setup:0x9B9=0x02) remains the only route.

CONCLUSION (triple-confirmed): the FPGA imaging path is held pre-init by the
CVF-Support-gated firmware IVSC init. No OS-reachable lever - I2C mode-switch
(full Windows sequence), GPIO, SPI, ACPI methods, or flash write (SMM_BWP=1) -
moves it. Software solve impossible on this unit; external SPI programmer
(Setup:0x9B9=0x02) or USB IR camera remain the only options. A reboot is needed
to clear the wedged spistub module + taint.

### Correction: the byte flip is necessary but NOT proven sufficient (2026-08-24)

Adversarial review flagged an overclaim: earlier notes here and an earlier
SPI_PROGRAMMER.md said that after Setup:0x9B9=0x02 "all the validated OS
machinery would work / no custom driver needed". This unit's OWN live testing
(branch fix/ljca-enum, machines/jester/ivsc-stack/DIAGNOSIS.md) disproves the
"stock stack just works" part:
- Under CVFS=2, stock in-kernel vsc-tp fails vsc_tp_probe() with two real bugs
  (IRQF_TRIGGER_FALLING on a PADCFG-locked wake pad; missing `wakeupfw` GPIO
  resource in the CVFS==2 _CRS branch). Both fixed by the out-of-tree
  ivsc-stack/vsc-tp-patched module (fixes 1+2, verified live). Ship these with
  the reflash.
- With 1+2 applied, wake pad GPI0 pin 23 read as hardware-locked OUTPUT-ONLY
  (PADCFG0=0x44000200), which cannot be an IRQ source. HOWEVER this was seen
  under a RUNTIME GNVS poke, which skips the firmware IVSC init; a real reflash
  latches CVF Support=2 pre-boot so the firmware bring-up configures the pad and
  may clear the wall. UNTESTED on a genuine cold boot.

Corrected claim: the flip is NECESSARY (re-enables the firmware IVSC init and
routes INTC1009 to the working LJCA bus) but end-to-end streaming is UNVERIFIED;
plan on shipping the vsc-tp patches and treat the pin-23 wall as a known residual
risk a cold boot may or may not clear. Value 0x02 (USB Bridge) is confirmed
correct over 0x01 (Native IOs): native SPI1 (00:1e.3) is firmware-disabled, so
Native IOs routes to a nonexistent controller. SPI_PROGRAMMER.md now states all
of this.

## jester: webcam CCM recalibrated after motherboard swap (2026-09-10)

The motherboard was replaced, which changed the camera picture (the IPU6
raw pipeline lives on the SoC; the OV2740 sensor in the lid stayed). The
2026-08-19 CCM was fitted on the old board. Refit with `webcam-calibrate`
(machines/jester/webcam-calibrate.py): chart on the EHOMEWEI panel at 35%
brightness, dark and flat captures to remove panel falloff and glare, rows
constrained to sum to 1. 23 usable patches, 5.2% mean residual. Redo after
any further board or camera change; the AGC step-size patch and the 1.3
contrast default in camera.nix were tuned on the old board and are the next
knobs if exposure hunts or contrast looks wrong.
