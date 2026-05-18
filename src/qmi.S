@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ qmi.S - RP2350 Quad Memory Interface (XIP flash controller) - M7 entry.
@
@ The bootrom hands off with QMI in a slow-but-safe SPI 03h read mode
@ (CLKDIV ~ 12 -> ~12.5 MHz SCK at clk_sys=150 MHz).  These helpers let
@ the application tighten that up.
@
@ CRITICAL: any function that writes QMI registers must NOT execute from
@ XIP itself, or an in-flight read for our next instruction can glitch
@ when CLKDIV changes mid-fetch.  All public functions in this file live
@ in .ramfunc, which the linker places at LMA = flash, VMA = SRAM; the
@ startup.S _reset prologue copies them into SRAM before main runs.
@
@ Public API:
@   qmi_set_clkdiv(div)            QMI_M0_TIMING.CLKDIV = div   (1..255)
@   qmi_flush_cache                blocking; clears the 16 KiB XIP cache
@
@ Reference: RP2350 datasheet sec 13.7 (QMI), sec 13.8 (XIP cache).
@ =============================================================================

    .include "rp2350.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ QMI_BASE,           0x400D0000
    .equ QMI_M0_TIMING,      0x0C        @ CLKDIV[7:0], RXDELAY[10:8], ...
    .equ QMI_TIMING_CLKDIV_MASK, 0xFF

    .equ XIP_CTRL_BASE,      0x400C8000
    .equ XIP_CTRL_CTRL,      0x00
    .equ XIP_CTRL_FLUSH,     0x04
    .equ XIP_CTRL_STAT,      0x08
    .equ XIP_STAT_FLUSH_READY, (1 << 1)

@ ----------------------------------------------------------------------------
@ qmi_set_clkdiv(div) - QMI_M0_TIMING.CLKDIV = div (low 8 bits).
@ Other timing fields preserved (RXDELAY, SELECT_SETUP, etc.).
@ Clobbers: r0-r3.
@
@ Must run from SRAM (.ramfunc) because the str updates the SCK divider
@ that's mid-stride for our own next instruction fetch.
@ ----------------------------------------------------------------------------
    .section .ramfunc.qmi_set_clkdiv, "ax"
    .thumb_func
    .global  qmi_set_clkdiv
qmi_set_clkdiv:
    @ Clamp div to 8 bits
    and     r0, r0, #0xFF

    ldr     r3, =QMI_BASE
    ldr     r1, [r3, #QMI_M0_TIMING]
    @ Clear CLKDIV (bits[7:0])
    bic     r1, r1, #QMI_TIMING_CLKDIV_MASK
    orr     r1, r1, r0
    str     r1, [r3, #QMI_M0_TIMING]

    @ Force cache flush so subsequent fetches go through the new timing
    @ (otherwise stale lines from the slow regime sit in cache).
    ldr     r3, =XIP_CTRL_BASE
    movs    r0, #1
    str     r0, [r3, #XIP_CTRL_FLUSH]
1:  ldr     r0, [r3, #XIP_CTRL_STAT]
    tst     r0, #XIP_STAT_FLUSH_READY
    beq     1b
    bx      lr

@ ----------------------------------------------------------------------------
@ qmi_flush_cache - blocking cache invalidate.  Useful for cold-cache
@ benchmarks.  Safe to run from XIP itself (XIP_CTRL writes don't change
@ the QMI timing in flight).
@ ----------------------------------------------------------------------------
    .section .text.qmi_flush_cache, "ax"
    .thumb_func
    .global  qmi_flush_cache
qmi_flush_cache:
    ldr     r3, =XIP_CTRL_BASE
    movs    r0, #1
    str     r0, [r3, #XIP_CTRL_FLUSH]
1:  ldr     r0, [r3, #XIP_CTRL_STAT]
    tst     r0, #XIP_STAT_FLUSH_READY
    beq     1b
    bx      lr
