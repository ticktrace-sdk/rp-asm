@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ xosc.S - Bring the RP2040 12 MHz crystal oscillator out of standby.
@
@ Datasheet ref: RP2040 sec 2.16.
@
@ Steps:
@   1. Program XOSC_STARTUP.DELAY = 47   (~1 ms with a 12 MHz crystal).
@   2. Program XOSC_CTRL with FREQ_RANGE=1_15MHZ | ENABLE=ENABLE.
@      The two fields share the same word so we write them together.
@   3. Spin reading XOSC_STATUS until the STABLE (bit 31) latches.
@
@ Same shape as the RP2350 driver - same XOSC IP, same control codes -
@ only the base address differs.  Kept as a separate file under
@ chips/rp2040/src/ so the RP2040 build doesn't depend on the RP2350 tree.
@ =============================================================================

    .include "rp2040.inc"

    .syntax unified
    .cpu    cortex-m0plus
    .thumb

@ ----------------------------------------------------------------------------
@ xosc_init - bring XOSC up and wait for STABLE.
@ Clobbers: r0-r2.
@ ----------------------------------------------------------------------------
    .section .text.xosc_init, "ax"
    .thumb_func
    .global  xosc_init
xosc_init:
    ldr     r0, =XOSC_BASE

    @ XOSC_STARTUP.DELAY
    movs    r1, #XOSC_STARTUP_DELAY
    str     r1, [r0, #XOSC_STARTUP]

    @ XOSC_CTRL = FREQ_RANGE | ENABLE
    ldr     r1, =(XOSC_CTRL_FREQ_1_15MHZ | XOSC_CTRL_ENABLE)
    str     r1, [r0, #XOSC_CTRL]

    @ Spin until STABLE (bit 31).  ARMv6-M has no BMI/BPL on flags directly
    @ paired with a load; explicit shift-then-bcc test.
1:  ldr     r1, [r0, #XOSC_STATUS]
    @ N flag will be set if bit 31 of r1 is 1, but ARMv6-M cmp #0 doesn't
    @ leave N reflecting bit 31; use a shift to put bit 31 into the carry/
    @ sign and test.
    asrs    r2, r1, #31              @ r2 = -1 if STABLE, 0 otherwise
    cmp     r2, #0
    beq     1b

    bx      lr
