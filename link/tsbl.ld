/* ============================================================================
 * tsbl.ld - TSBL image, up to 24 KiB - 256 B at 0x10001000.
 *
 * The slot is 24 KiB but the last 256 B holds the footer (appended by
 * mkmanifest+mkfirmware), so the linker budget is FLASH LENGTH = 24K - 256.
 * Any TSBL flavor (bypass, ab, dfu, signed, recovery, or combinations)
 * links with this script.
 * ========================================================================== */

ENTRY(_tsbl_reset)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x10001000, LENGTH = 24K - 256
    SRAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 512K
}

SECTIONS
{
    .text 0x10001000 : ALIGN(4)
    {
        KEEP(*(.tsbl_vectors))
        . = 0x180;
        KEEP(*(.tsbl_image_def))
        *(.text._tsbl_reset)
        *(.text.crc32_compute)
        *(.text._tsbl_halt)
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
    } > FLASH

    /DISCARD/ : { *(.ARM.exidx*) *(.ARM.attributes) *(.comment) }

    _stack_top = ORIGIN(SRAM) + LENGTH(SRAM) - 4;
}
