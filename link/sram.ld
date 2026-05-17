/* SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Copyright (C) 2026 Amken LLC <https://amken.io>
 *
 * This file is part of the Amken RP2350 Assembly SDK.
 * Licensed under AGPL-3.0-or-later; commercial license available.
 * See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.
 */

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
        . = 0x180;                      /* park IMAGE_DEF past 68-entry vectors */
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

    /* SRAM-resident image: .ramfunc has the same VMA and LMA - no copy
       needed.  Still bracket it with the load symbols so startup.S can
       call its copy loop unconditionally. */
    .ramfunc : ALIGN(4)
    {
        __ramfunc_start__ = .;
        *(.ramfunc*)
        . = ALIGN(4);
        __ramfunc_end__ = .;
    } > SRAM
    __ramfunc_load__ = __ramfunc_start__;

    .bss (NOLOAD) : ALIGN(4)
    {
        _sbss = .;
        __bss_start__ = .;          /* C-runtime alias */
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
        __bss_end__ = .;
    } > SRAM

    /* Top-of-SRAM stack.  Reserve a 4-byte gap so a stray push at top
     * doesn't alias the last SRAM word. */
    _stack_top = ORIGIN(SRAM) + LENGTH(SRAM) - 4;

    /DISCARD/ : { *(.ARM.exidx*) *(.ARM.attributes) *(.comment) }
}
