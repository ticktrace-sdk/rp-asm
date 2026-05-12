/* ============================================================================
 * qemu.ld - linker script for QEMU's mps2-an505 (Cortex-M33) generic harness.
 *
 * This is NOT the RP2350 layout.  T2 only verifies ARMv8-M ISA / vector
 * behaviour on a generic board so we can quickly catch encoding bugs that
 * would never get out of T1.
 *
 * mps2-an505 secure boot memory map (QEMU 8.x):
 *   0x10000000  ZBT SSRAM1 (Secure)  - 4 MiB - boot ROM target.
 *               The CPU resets fetching SP/PC from this region.
 *   0x28000000  PSRAM (Secure)       - additional RAM, but boot is from SSRAM1.
 *
 * We place .text + .vectors at 0x10000000 and let .data/.bss fall through
 * the same image (semihosting tests don't need a separate RW region).
 * Stack is at the end of a 64 KiB carve-out for headroom.
 * ========================================================================== */

ENTRY(_start)

MEMORY
{
    SSRAM1 (rwx) : ORIGIN = 0x10000000, LENGTH = 4M
}

SECTIONS
{
    .text 0x10000000 : ALIGN(4)
    {
        KEEP(*(.vectors))
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
    } > SSRAM1

    .data : ALIGN(4)
    {
        *(.data*)
    } > SSRAM1

    .bss (NOLOAD) : ALIGN(4)
    {
        *(.bss*)
        *(COMMON)
    } > SSRAM1

    _stack_top = ORIGIN(SSRAM1) + 0x10000;   /* 64 KiB into SSRAM1 */

    /DISCARD/ : { *(.ARM.exidx*) *(.ARM.attributes) *(.comment) }
}
