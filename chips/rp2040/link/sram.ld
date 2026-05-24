/* SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Copyright (C) 2026 Amken LLC <https://www.amken.us>
 *
 * This file is part of the ticktrace Assembly SDK.
 * Licensed under AGPL-3.0-or-later; commercial license available.
 * See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.
 */

/* ============================================================================
 * sram.ld - SRAM-resident image for RP2040 (loaded via BOOTSEL UF2)
 *
 * RP2040 has 4 x 64 KiB + 2 x 4 KiB SRAM banks at 0x20000000.  The bottom
 * 256 KiB is striped (banks 0..3), then 4 KiB SRAM4 at 0x20040000 and
 * 4 KiB SRAM5 at 0x20041000 - 264 KiB total.  We bracket the contiguous
 * stripe and let the stack grow down from the top of SRAM5.
 *
 * Layout:
 *   .text {
 *     .vectors        @ 0x20000000  vector table (must be first; M0+ bootrom
 *                                    loads SP = *0x20000000 and PC = *0x20000004
 *                                    when BOOTSEL hands off to an SRAM image)
 *     .text.*         @ code
 *     .rodata.*       @ strings, constants
 *   }
 *   .data    [empty in M2]
 *   .bss     [empty in M2]
 *   stack    grows down from end of SRAM5
 * ========================================================================== */

ENTRY(_reset)

MEMORY
{
    SRAM (rwx) : ORIGIN = 0x20000000, LENGTH = 264K
}

SECTIONS
{
    .text 0x20000000 : ALIGN(4)
    {
        KEEP(*(.vectors))
        *(.text._reset)
        *(.text.main)
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
    } > SRAM

    .data : ALIGN(4)
    {
        __data_start__ = .;
        *(.data*)
        . = ALIGN(4);
        __data_end__ = .;
    } > SRAM
    __data_load__ = __data_start__;

    /* SRAM-resident image: .ramfunc has the same VMA and LMA - no copy
       needed.  Still bracket it with the load symbols so startup.S can
       call its copy loop unconditionally.  Empty .ramfunc -> the loop
       exits on the first iteration. */
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
