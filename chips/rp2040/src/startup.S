@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ startup.S - Cortex-M0+ vector table + reset entry (RP2040)
@
@ Image layout (loaded by BOOTSEL into SRAM @ 0x20000000):
@   0x000  vector table       (48 entries / 192 bytes; 16 core + 32 external)
@   0x0C0  _reset             (entry point, also vec[1])
@   ...    rest of .text/.rodata
@
@ Bootrom flow on UF2 SRAM load:
@   1. UF2 blocks written to SRAM at their target addresses (family 0xE48BFF56).
@   2. SP <- *0x20000000
@      PC <- *0x20000004
@   So vec[0] must be top of stack, vec[1] the reset handler.
@   (RP2040 has no IMAGE_DEF / picobin block; the bootrom just trusts the SRAM
@   image's vector table.)
@
@ Compared to the RP2350 startup:
@   - 48-entry vector table (vs 68 on RP2350; M0+ has fewer exception slots
@     and the RP2040 has 26 external IRQs, padded to 32 for power-of-2 VTOR
@     alignment).
@   - No SecureFault/MemManage/BusFault/UsageFault/DebugMon - these slots are
@     all "reserved" on ARMv6-M and we leave them at 0.
@   - No RCP coprocessor init, no MSPLIM zero; M0+ has neither.
@   - No IMAGE_DEF block; the RP2040 bootrom doesn't scan for one.
@ =============================================================================

    .include "rp2040.inc"

    .syntax unified
    .cpu    cortex-m0plus
    .thumb

@ ----------------------------------------------------------------------------
@ Vector table
@ ----------------------------------------------------------------------------
    .section .vectors, "ax"
    .align   2
    .global  _vectors
_vectors:
    .word _stack_top            @  0  Initial SP
    .word _reset + 1            @  1  Reset (Thumb bit set)
    .word _halt  + 1            @  2  NMI
    .word _halt  + 1            @  3  HardFault
    .word 0                     @  4  reserved
    .word 0                     @  5  reserved
    .word 0                     @  6  reserved
    .word 0                     @  7  reserved
    .word 0                     @  8  reserved
    .word 0                     @  9  reserved
    .word 0                     @ 10  reserved
    .word _halt  + 1            @ 11  SVCall
    .word 0                     @ 12  reserved
    .word 0                     @ 13  reserved
    .word _halt  + 1            @ 14  PendSV
    .word _halt  + 1            @ 15  SysTick
    @ External IRQs 0..31 (RP2040 only uses 0..25; 26..31 are reserved).
    .rept 32
    .word _halt + 1
    .endr

@ ----------------------------------------------------------------------------
@ Reset handler
@ Bootrom has already set SP/PC from the vector table. We:
@   1. Copy the 48-entry vector table to a 256-byte-aligned SRAM slot and
@      point VTOR at it so nvic_install_handler() can patch slots at runtime.
@   2. Copy .data and .ramfunc from their load addresses (in flash for XIP
@      builds, same address for SRAM builds) to their VMAs.
@   3. Zero .bss.
@   4. Bring io_bank0 / pads_bank0 out of reset.  uart0 is released by
@      uart_init when the caller actually wants UART.
@   5. Hand off to main.
@
@ ARMv6-M has no Thumb-2 IT blocks: every conditional store uses an explicit
@ branch.  ARMv6-M also has no UMULL/SDIV; M2 doesn't need either.
@ ----------------------------------------------------------------------------
    .section .text._reset, "ax"
    .thumb_func
    .align   2
    .global  _reset
_reset:
    @ ---- 1. Vector relocation: copy 48 words to _ram_vectors, set VTOR -----
    ldr     r0, =_vectors
    ldr     r1, =_ram_vectors
    movs    r2, #48                         @ 16 core + 32 external
2:  ldr     r3, [r0]
    str     r3, [r1]
    adds    r0, #4
    adds    r1, #4
    subs    r2, #1
    bne     2b

    ldr     r0, =SCB_VTOR
    ldr     r1, =_ram_vectors
    str     r1, [r0]

    @ ---- 2a. Copy .data from LMA to VMA -----------------------------------
    ldr     r0, =__data_load__
    ldr     r1, =__data_start__
    ldr     r2, =__data_end__
3:  cmp     r1, r2
    bge     4f
    ldr     r3, [r0]
    str     r3, [r1]
    adds    r0, #4
    adds    r1, #4
    b       3b
4:

    @ ---- 2b. Copy .ramfunc from LMA to VMA --------------------------------
    ldr     r0, =__ramfunc_load__
    ldr     r1, =__ramfunc_start__
    ldr     r2, =__ramfunc_end__
5:  cmp     r1, r2
    bge     6f
    ldr     r3, [r0]
    str     r3, [r1]
    adds    r0, #4
    adds    r1, #4
    b       5b
6:

    @ ---- 3. Zero .bss -----------------------------------------------------
    ldr     r0, =__bss_start__
    ldr     r1, =__bss_end__
    movs    r2, #0
7:  cmp     r0, r1
    bge     8f
    str     r2, [r0]
    adds    r0, #4
    b       7b
8:

    @ ---- 4. Deassert io_bank0 + pads_bank0 resets -------------------------
    @ Build the mask (1 << io_bank0) | (1 << pads_bank0) without a runtime
    @ shift since constants are small enough to be encoded directly.
    movs    r3, #1
    lsls    r3, #RESETS_io_bank0            @ r3 = 1 << 5
    movs    r4, #1
    lsls    r4, #RESETS_pads_bank0          @ r4 = 1 << 8
    orrs    r3, r4                          @ r3 = 0x120

    @ Clear those bits via the atomic CLR alias.
    ldr     r0, =RESETS_BASE + ATOMIC_CLR + RESETS_RESET
    str     r3, [r0]

    @ Spin until both blocks report RESET_DONE.
    ldr     r0, =RESETS_BASE + RESETS_RESET_DONE
9:  ldr     r1, [r0]
    ands    r1, r3
    cmp     r1, r3
    bne     9b

    @ ---- 5. Hand off to main ----------------------------------------------
    b       main

@ ----------------------------------------------------------------------------
@ _halt - parking spot for unimplemented vectors. WFI keeps the core cold.
@ ----------------------------------------------------------------------------
    .thumb_func
    .global  _halt
_halt:
    wfi
    b       _halt

@ ----------------------------------------------------------------------------
@ _ram_vectors - SRAM copy of the vector table, populated by _reset.
@
@ ARMv6-M VTOR (RP2040 has it as an implementation defined option, and the
@ RP2040 enables it - datasheet sec 2.4.4.6) requires the vector table to be
@ aligned to the next power of 2 >= table size.  48 * 4 = 192 bytes; the
@ smallest power of 2 >= 192 is 256, so we align to 256 bytes here.
@ ----------------------------------------------------------------------------
    .section .bss._ram_vectors, "aw", %nobits
    .align   8                       @ 2^8 = 256-byte alignment for VTOR
    .global  _ram_vectors
_ram_vectors:
    .space   48 * 4                  @ 48 * 4 = 192 bytes
