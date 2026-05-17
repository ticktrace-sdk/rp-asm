@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ xosc.S - Bring the 12 MHz crystal oscillator out of standby.
@
@ Datasheet ref: RP2350 sec 8.2.
@
@ Steps:
@   1. Program XOSC_STARTUP.DELAY = 47   (~1 ms with a 12 MHz crystal).
@   2. Program XOSC_CTRL with FREQ_RANGE=1_15MHZ | ENABLE=ENABLE.
@      The two fields share the same word so we write them together.
@   3. Spin reading XOSC_STATUS until the STABLE (bit 31) latches.
@
@ Cycle budget (with the crystal physically present):
@   ~6 stores at 2 cycles each + a polling loop that runs for the startup
@   delay (~12000 cycles @ 12 MHz, ~150000 cycles once we re-tune to clk_sys).
@ When called from Unicorn we mock STABLE so the loop is bounded.
@ =============================================================================

    .include "rp2350.inc"
    .include "clocks.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ xosc_init - bring XOSC up and wait for STABLE.
@ Clobbers: r0-r3.
@ ----------------------------------------------------------------------------
    .section .text.xosc_init, "ax"
    .thumb_func
    .global  xosc_init
xosc_init:
    ldr     r0, =XOSC_BASE

    @ XOSC_STARTUP.DELAY  (3 cycles)
    movs    r1, #XOSC_STARTUP_DELAY
    str     r1, [r0, #XOSC_STARTUP]

    @ XOSC_CTRL = FREQ_RANGE | ENABLE   (4 cycles inc. the ldr)
    ldr     r1, =(XOSC_CTRL_FREQ_1_15MHZ | XOSC_CTRL_ENABLE)
    str     r1, [r0, #XOSC_CTRL]

    @ Spin until STABLE (bit 31).  3-cycle inner loop:  ldr / cmp / bpl.
1:  ldr     r1, [r0, #XOSC_STATUS]
    cmp     r1, #0
    bpl     1b                      @ N flag clear -> bit 31 not set

    bx      lr
