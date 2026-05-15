/* ============================================================================
 * ssbl.ld - SSBL image, 4 KiB at 0x10000000.
 *
 * .ssbl_vectors at slot base, .ssbl_image_def at +0x180 (FSBL scan range),
 * code and rodata follow. The slot footer (256 B at +0xF00) is NOT part of
 * this binary - it is appended by tools/cmd/rpasm/mkmanifest+mkfirmware so
 * a TSBL flavor change doesn't require re-flashing the SSBL.
 *
 * Stack lives in SRAM (the SSBL only needs ~16 bytes of stack for the one
 * bl into crc32_compute).
 * ========================================================================== */

ENTRY(_ssbl_reset)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x10000000, LENGTH = 4K
    SRAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 512K
}

SECTIONS
{
    .text 0x10000000 : ALIGN(4)
    {
        KEEP(*(.ssbl_vectors))
        . = 0x180;                      /* park IMAGE_DEF after the vectors */
        KEEP(*(.ssbl_image_def))
        *(.text._ssbl_reset)
        *(.text.crc32_compute)
        *(.text._ssbl_halt)
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
    } > FLASH

    /DISCARD/ : { *(.ARM.exidx*) *(.ARM.attributes) *(.comment) }

    _stack_top = ORIGIN(SRAM) + LENGTH(SRAM) - 4;
}
