/* SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Copyright (C) 2026 Amken LLC <https://amken.io>
 *
 * This file is part of the Amken RP2350 Assembly SDK.
 * Licensed under AGPL-3.0-or-later; commercial license available.
 * See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.
 */

/* ============================================================================
 * app_at_0x10080000.ld - App image linked for slot B (480 KiB - 256 B at
 * 0x10080000). Used only by `-ab` TSBL flavors.
 *
 * Identical layout to link/app_at_0x10008000.ld except for the base
 * address - a slot-B build of an app is byte-different from a slot-A build
 * because every absolute address reference (literal pools, ldr =label)
 * resolves to a different value.
 * ========================================================================== */

ENTRY(_reset)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x10080000, LENGTH = 480K - 256
    SRAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 512K
}

SECTIONS
{
    .text 0x10080000 : ALIGN(4)
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
