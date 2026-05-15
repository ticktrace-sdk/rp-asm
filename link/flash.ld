/* ============================================================================
 * flash.ld - XIP-resident image for RP2350 (loaded via BOOTSEL UF2 -> flash)
 *
 * Identical section layout to sram.ld, but linked at 0x10000000 (the XIP
 * window).  RP2350's bootrom does its own QSPI/XIP bring-up before handing
 * off, so we don't need a separate boot2 image like RP2040 did.
 *
 * Stack still lives in SRAM (set _stack_top at the top of bank 0..7).
 *
 * .data is currently zero-sized in this SDK; if that ever stops being true,
 * teach _reset to copy from LMA (flash) to VMA (SRAM) before main runs.
 * ========================================================================== */

ENTRY(_reset)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x10000000, LENGTH = 2M
    SRAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 512K
}

SECTIONS
{
    .text 0x10000000 : ALIGN(4)
    {
        KEEP(*(.vectors))
        . = 0x180;                      /* park IMAGE_DEF past 68-entry vectors */
        KEEP(*(.image_def))
        *(.text._reset)
        *(.text.main)
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
    } > FLASH

    .data : ALIGN(4)
    {
        *(.data*)
        . = ALIGN(4);
    } > SRAM AT > FLASH

    /* RAM functions: code that must execute from SRAM (e.g. QMI
       reconfiguration that would glitch if running from XIP).  LMA in
       flash, VMA in SRAM; copied to SRAM by _reset before main runs. */
    .ramfunc : ALIGN(4)
    {
        __ramfunc_start__ = .;
        *(.ramfunc*)
        . = ALIGN(4);
        __ramfunc_end__ = .;
    } > SRAM AT > FLASH
    __ramfunc_load__ = LOADADDR(.ramfunc);

    .bss (NOLOAD) : ALIGN(4)
    {
        _sbss = .;
        __bss_start__ = .;          /* C-runtime alias for _c_runtime_init */
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
        __bss_end__ = .;
    } > SRAM

    _stack_top = ORIGIN(SRAM) + LENGTH(SRAM) - 4;

    /DISCARD/ : { *(.ARM.exidx*) *(.ARM.attributes) *(.comment) }
}
