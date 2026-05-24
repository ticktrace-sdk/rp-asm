/* SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Copyright (C) 2026 Amken LLC <https://www.amken.us>
 *
 * This file is part of the ticktrace Assembly SDK.
 * Licensed under AGPL-3.0-or-later; commercial license available.
 * See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.
 */

/* ============================================================================
 * flash.ld - XIP-resident image for RP2040 (drag-droppable on real silicon)
 *
 * Flash layout on RP2040:
 *   0x10000000  BOOT2 stage (256 bytes; the bootrom CRC32-checks the last 4
 *               bytes and copies the rest to 0x20041F00 in SRAM5 before
 *               jumping into it).  This stage configures QSPI XIP then jumps
 *               to the app's vector table.
 *   0x10000100  app vector table + image (the bootrom hands SP / PC from
 *               the first two words of this region after BOOT2 returns).
 *
 * Because we're at XIP (read-only), .data needs an LMA in flash with a VMA
 * in SRAM and the startup code has to copy it.  Same goes for .ramfunc.
 * ========================================================================== */

ENTRY(_reset)

MEMORY
{
    BOOT2 (rx) : ORIGIN = 0x10000000, LENGTH = 256
    FLASH (rx) : ORIGIN = 0x10000100, LENGTH = 2M - 256
    SRAM  (rwx): ORIGIN = 0x20000000, LENGTH = 264K
}

SECTIONS
{
    /* BOOT2 occupies exactly 256 bytes at 0x10000000.
     * Layout:
     *   bytes 0..251  - boot2 stub code, zero-filled gap, literal pool
     *   bytes 252..255 - CRC32-MPEG2 over bytes 0..251 (patched by
     *                    tools/boot2_crc.py after objcopy emits the .bin)
     *
     * The `. = ORIGIN(BOOT2) + LENGTH(BOOT2) - 4;` step jumps the location
     * counter forward past the boot2 code to the CRC slot.  The gap is
     * filled with zeros via `= 0x00` on the output section command below.
     */
    .boot2 ORIGIN(BOOT2) : {
        __boot2_start__ = .;
        KEEP(*(.boot2))
        . = ALIGN(4);
        . = ORIGIN(BOOT2) + LENGTH(BOOT2) - 4;
        __boot2_crc__ = .;
        LONG(0)                                 /* CRC placeholder */
        __boot2_end__ = .;
    } > BOOT2 = 0x00

    .text 0x10000100 : ALIGN(4)
    {
        KEEP(*(.vectors))
        *(.text._reset)
        *(.text.main)
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
    } > FLASH

    /* .data has an LMA in flash and a VMA in SRAM. startup copies it. */
    .data : ALIGN(4)
    {
        __data_start__ = .;
        *(.data*)
        . = ALIGN(4);
        __data_end__ = .;
    } > SRAM AT > FLASH
    __data_load__ = LOADADDR(.data);

    /* .ramfunc same shape: code that has to run from SRAM (e.g. functions
     * that mutate XIP config and can't be fetched out of XIP at the same
     * time).  Empty in M2 - kept here so SRAM and flash linker scripts have
     * the same exported symbols. */
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
