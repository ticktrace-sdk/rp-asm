/* ============================================================================
 * sram.ld - SRAM-resident image for RP2350 (loaded via BOOTSEL UF2)
 *
 * RP2350 has 8 x 64 KiB SRAM banks at 0x20000000 (512 KiB contiguous),
 * plus 2 x 4 KiB scratch banks not used here.
 *
 * Layout (kept in one read-execute output section so the bootrom only has
 * to scan a single region for the IMAGE_DEF magic):
 *
 *   .text {
 *     .vectors        @ 0x20000000  vector table (must be first)
 *     .image_def      @ within first 4 KiB - bootrom scans this window
 *     .text.*         @ code
 *     .rodata.*       @ strings, constants
 *   }
 *   .data    [empty in v0.1]
 *   .bss     [empty in v0.1]
 *   stack    grows down from end of SRAM
 * ========================================================================== */

ENTRY(_reset)

MEMORY
{
    SRAM (rwx) : ORIGIN = 0x20000000, LENGTH = 512K
}

SECTIONS
{
    .text 0x20000000 : ALIGN(4)
    {
        KEEP(*(.vectors))
        . = 0x40;                       /* park IMAGE_DEF at a known offset */
        KEEP(*(.image_def))
        *(.text._reset)
        *(.text.main)
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
    } > SRAM

    .data : ALIGN(4)
    {
        *(.data*)
        . = ALIGN(4);
    } > SRAM

    .bss (NOLOAD) : ALIGN(4)
    {
        _sbss = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > SRAM

    /* Top-of-SRAM stack.  Reserve a 4-byte gap so a stray push at top
     * doesn't alias the last SRAM word. */
    _stack_top = ORIGIN(SRAM) + LENGTH(SRAM) - 4;

    /DISCARD/ : { *(.ARM.exidx*) *(.ARM.attributes) *(.comment) }
}
