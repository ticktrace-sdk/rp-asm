/* SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Copyright (C) 2026 Amken LLC <https://www.amken.us>
 *
 * This file is part of the ticktrace Assembly SDK.
 * Licensed under AGPL-3.0-or-later; commercial license available.
 * See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.
 */

/* ============================================================================
 * app_at_0x10008000.ld - App image linked for slot A (480 KiB - 256 B at
 * 0x10008000). Used when the SDK's bootloader chain is shipped; the SSBL
 * + TSBL-bypass occupies [0x10000000 .. 0x10008000) and hands off to the
 * app at 0x10008000.
 *
 * Identical layout to link/flash.ld except for the base address and the
 * slot length budget (FLASH LENGTH = 480K - 256 leaves room for the app
 * footer at slot end). Apps continue to use .vectors / .image_def section
 * names, so existing src/startup.S works unchanged.
 * ========================================================================== */

ENTRY(_reset)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x10008000, LENGTH = 480K - 256
    SRAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 512K
}

SECTIONS
{
    .text 0x10008000 : ALIGN(4)
    {
        KEEP(*(.vectors))
        . = 0x180;
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
        __bss_start__ = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
        __bss_end__ = .;
    } > SRAM

    _stack_top = ORIGIN(SRAM) + LENGTH(SRAM) - 4;

    /DISCARD/ : { *(.ARM.exidx*) *(.ARM.attributes) *(.comment) }
}
