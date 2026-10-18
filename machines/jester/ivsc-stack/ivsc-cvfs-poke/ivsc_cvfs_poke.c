// SPDX-License-Identifier: GPL-2.0-only
/*
 * IVSC transport route poke: force GNVS byte CVFS to 2 (LJCA) before SPI
 * enumeration, so ACPI INTC1009 (the IVSC vsc-tp transport)'s _CRS resolves
 * to \_SB.PC00.XHCI.RHUB.HS08.VSPI (LJCA USB-SPI bridge) instead of
 * \_SB.PC00.SPI1 (native SerialIO SPI1, PCI 00:1e.3), which is
 * function-disabled and SMM-locked on this firmware.
 *
 * Proven live on this machine (see ../DIAGNOSIS.md): CVFS=0x0 (native mode),
 * CUPN=0x8 (LJCA port 8 is the intended alternate route). Writing CVFS=2
 * before spi_ljca/mei_vsc probe makes the kernel enumerate INTC1009 on the
 * LJCA spi0 controller, which vsc-tp's ACPI match table already covers.
 *
 * GNVS is an ACPI OperationRegion (SystemMemory) that BIOS fills at boot.
 * There is no simple ACPICA API to resolve an arbitrary OperationRegion's
 * physical base at runtime without a bespoke AML walk, so this uses the
 * live-confirmed physical base (0x5A1A3000) but never trusts it blindly:
 * before writing, it reads CUPN (offset 0xB7A) and refuses to write unless
 * CUPN == 0x08, the signature observed on this machine. A firmware update
 * that relocates GNVS will very likely also change CUPN, so the guard
 * fails closed (logs and exits) instead of corrupting an unrelated region.
 *
 * TODO(portability): replace the hardcoded base with a real ACPI GNVS
 * lookup (walk \_SB for the OperationRegion via acpi_evaluate_object /
 * a custom address-space handler) if this needs to survive relocation.
 * Out of scope here: single-machine (jester) fix.
 */

#include <linux/acpi.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/module.h>

#define GNVS_PHYS_BASE   0x5A1A3000UL
#define GNVS_LEN         0x0D09UL
#define CVFS_OFFSET      0xB79UL
#define CUPN_OFFSET      0xB7AUL
#define CUPN_EXPECTED    0x08
#define CVFS_LJCA        0x02

static int __init ivsc_cvfs_poke_init(void)
{
	void *gnvs;
	volatile u8 *cvfs_p, *cupn_p;
	unsigned long page_base = GNVS_PHYS_BASE & PAGE_MASK;
	unsigned long page_off = GNVS_PHYS_BASE - page_base;
	unsigned long map_len = round_up(page_off + GNVS_LEN, PAGE_SIZE);
	u8 cupn, cvfs_before, cvfs_after;

	/*
	 * GNVS is ACPI NVS: RAM-backed reserved memory, not MMIO. ioremap()
	 * refuses it ("ioremap of GNVS failed" on this machine); memremap()
	 * with MEMREMAP_WB is the correct API for reserved RAM regions and
	 * gives a normal (cached, coherent with AML's SystemMemory accesses)
	 * mapping.
	 */
	gnvs = memremap(page_base, map_len, MEMREMAP_WB);
	if (!gnvs) {
		pr_err("ivsc-cvfs-poke: memremap of GNVS @ %#lx (%lu bytes) failed\n",
		       page_base, map_len);
		return -ENOMEM;
	}
	cvfs_p = (volatile u8 *)gnvs + page_off + CVFS_OFFSET;
	cupn_p = (volatile u8 *)gnvs + page_off + CUPN_OFFSET;

	cupn = *cupn_p;
	if (cupn != CUPN_EXPECTED) {
		pr_err("ivsc-cvfs-poke: GNVS signature mismatch (CUPN=%#x, expected %#x) "
		       "at phys %#lx - refusing to write, GNVS may have moved\n",
		       cupn, CUPN_EXPECTED, GNVS_PHYS_BASE);
		memunmap(gnvs);
		return -ENODEV;
	}

	cvfs_before = *cvfs_p;
	pr_info("ivsc-cvfs-poke: GNVS signature OK (CUPN=%#x), CVFS currently %#x\n",
		cupn, cvfs_before);

	if (cvfs_before == CVFS_LJCA) {
		pr_info("ivsc-cvfs-poke: CVFS already %#x, nothing to do\n", CVFS_LJCA);
		memunmap(gnvs);
		return 0;
	}

	/*
	 * ACPI NVS is left writable by the firmware (the OS updates GNVS fields
	 * at runtime for AML to see them), so write directly. The readback
	 * below reports clearly (-EIO) if the region turns out write-protected
	 * instead of silently failing.
	 */
	*cvfs_p = CVFS_LJCA;
	mb();

	cvfs_after = *cvfs_p;
	if (cvfs_after != CVFS_LJCA) {
		pr_err("ivsc-cvfs-poke: write did not take (CVFS reads back %#x, "
		       "expected %#x) - GNVS is write-protected, fall back "
		       "to an SSDT override\n", cvfs_after, CVFS_LJCA);
		memunmap(gnvs);
		return -EIO;
	}

	pr_info("ivsc-cvfs-poke: CVFS %#x -> %#x, IVSC transport should now route to LJCA\n",
		cvfs_before, cvfs_after);

	memunmap(gnvs);
	return 0;
}

static void __exit ivsc_cvfs_poke_exit(void)
{
}

module_init(ivsc_cvfs_poke_init);
module_exit(ivsc_cvfs_poke_exit);

MODULE_AUTHOR("Jonas Emilsson");
MODULE_DESCRIPTION("Poke GNVS CVFS=2 early so IVSC transport routes to LJCA SPI");
MODULE_LICENSE("GPL");
