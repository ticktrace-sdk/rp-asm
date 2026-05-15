@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ watchdog.S - RP2350 watchdog: disable / arm / feed.
@
@ Datasheet ref: RP2350 sec 12.9.
@
@ The watchdog runs off the WATCHDOG tick (set up in tick.S to 1 us).  The
@ TIME field is 24 bits, so the maximum timeout is ~16.7 s.  We use atomic
@ aliases so we never race with anyone else clearing CTRL bits.
@
@ All three functions are leaf functions (~6-10 cycles each).
@ =============================================================================

    .include "rp2350.inc"
    .include "clocks.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ watchdog_disable - clear ENABLE.
@ Clobbers: r0-r1.
@ ----------------------------------------------------------------------------
    .section .text.watchdog_disable, "ax"
    .thumb_func
    .global  watchdog_disable
watchdog_disable:
    ldr     r0, =WATCHDOG_BASE + ATOMIC_CLR + WATCHDOG_CTRL
    ldr     r1, =WATCHDOG_CTRL_ENABLE
    str     r1, [r0]
    bx      lr

@ ----------------------------------------------------------------------------
@ watchdog_enable - load timeout (microseconds) and arm.
@ Input  : r0 = timeout in microseconds (max 0xFFFFFF -> ~16.7 s)
@ Clobbers: r0-r3.
@
@ The hardware reloads from LOAD whenever LOAD is written; CTRL.TIME is
@ the live counter (RO in practice) - we set it via LOAD.
@ ----------------------------------------------------------------------------
    .section .text.watchdog_enable, "ax"
    .thumb_func
    .global  watchdog_enable
watchdog_enable:
    @ Clamp to 24-bit  (movw + ldr to mask high byte)
    ldr     r1, =0x00FFFFFF
    ands    r0, r1

    ldr     r2, =WATCHDOG_BASE
    str     r0, [r2, #WATCHDOG_LOAD]

    @ Set ENABLE bit via atomic SET
    ldr     r3, =WATCHDOG_BASE + ATOMIC_SET + WATCHDOG_CTRL
    ldr     r1, =WATCHDOG_CTRL_ENABLE
    str     r1, [r3]
    bx      lr

@ ----------------------------------------------------------------------------
@ watchdog_feed - reload the counter from LOAD without disturbing CTRL.
@ Clobbers: r0-r1.
@ ----------------------------------------------------------------------------
    .section .text.watchdog_feed, "ax"
    .thumb_func
    .global  watchdog_feed
watchdog_feed:
    ldr     r0, =WATCHDOG_BASE
    ldr     r1, [r0, #WATCHDOG_LOAD]        @ read current LOAD
    str     r1, [r0, #WATCHDOG_LOAD]        @ writing LOAD reloads counter
    bx      lr
