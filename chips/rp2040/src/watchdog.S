@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ watchdog.S - RP2040 watchdog disable + tick generator.
@
@ Datasheet ref: RP2040 sec 4.7.
@
@ On RP2040 the WATCHDOG block owns the TICK generator that feeds TIMER, the
@ watchdog itself, and (via SIO) the M0+ SysTick. WATCHDOG_TICK has bits:
@   [8:0]  CYCLES   how many clk_ref ticks per 1 us tick
@   [9]    ENABLE   enable the tick generator
@   [10]   RUNNING  status, read-only
@
@ For a 12 MHz XOSC -> clk_ref path, CYCLES = 12 gives a 1 MHz tick.
@ (The RP2040 SDK's watchdog_start_tick(cycles=12) does the same write.)
@
@ Compared to RP2350: RP2040 has no separate TICK peripheral. The tick is
@ baked into WATCHDOG_TICK; no per-timer/wd/proc dividers.
@ =============================================================================

    .include "rp2040.inc"

    .syntax unified
    .cpu    cortex-m0plus
    .thumb

@ ----------------------------------------------------------------------------
@ watchdog_disable - clear CTRL.ENABLE.
@ Clobbers: r0, r1.
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
@ tick_init - enable the 1 MHz tick generator for clk_ref = 12 MHz.
@   WATCHDOG_TICK = ENABLE | 12
@
@ Provided as a separate symbol so main.S can call tick_init exactly the way
@ the RP2350 boot path does (where tick_init lives in its own file). On
@ RP2040 it's a one-store function.
@ Clobbers: r0, r1.
@ ----------------------------------------------------------------------------
    .section .text.tick_init, "ax"
    .thumb_func
    .global  tick_init
tick_init:
    ldr     r0, =WATCHDOG_BASE + WATCHDOG_TICK
    movs    r1, #WATCHDOG_TICK_CYCLES_12
    movs    r2, #1
    lsls    r2, #9                          @ r2 = ENABLE bit
    orrs    r1, r2
    str     r1, [r0]
    bx      lr
