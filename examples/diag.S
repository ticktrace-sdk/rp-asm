@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/diag.S - stage-blinker for bisecting the M2 boot hang on real silicon.
@
@ Same call sequence as src/main.S, but between each step we flash the LED a
@ stage-numbered number of times.  If the board hangs at stage K, you see
@ exactly K bursts of flashes, then darkness.
@
@   1 flash  -> entered main() (post _reset, post bootrom)
@   2        -> xosc_init returned
@   3        -> pll_sys_150_mhz returned
@   4        -> pll_usb_48_mhz returned
@   5        -> clocks_init returned  (clk_sys now 150 MHz - blinks get fast)
@   6        -> tick_init returned
@   7        -> watchdog_disable returned
@   8        -> uart0_init returned
@   9        -> clocks_post_pll_uart_baud_fixup returned
@  10        -> heartbeat (everything succeeded - repeats forever)
@
@ The LED setup is inlined (same MMIO sequence as gpio_led_init) so we don't
@ depend on anything before stage 1 being correct.  Pre-clocks_init the busy
@ delays look slow (running on whatever bootrom left); post-clocks_init they
@ look fast.  The COUNT of flashes per burst is what matters, not the speed.
@ =============================================================================

    .include "rp2350.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    @ Busy-loop iteration counts.  3-cycle inner body (subs+bne) so:
    @   @ 6 MHz ROSC : DELAY_ON = ~100 ms, DELAY_OFF = ~250 ms, DELAY_GAP = ~1.5 s
    @   @ 150 MHz    : DELAY_ON = ~4 ms,   DELAY_OFF = ~10 ms,  DELAY_GAP = ~60 ms
    .equ DELAY_ON,    200000
    .equ DELAY_OFF,   500000
    .equ DELAY_GAP,   3000000

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    bl      diag_led_init

    movs    r0, #1                  @ stage 1: reached main
    bl      blink_n

    bl      xosc_init
    movs    r0, #2
    bl      blink_n

    bl      pll_sys_150_mhz
    movs    r0, #3
    bl      blink_n

    bl      pll_usb_48_mhz
    movs    r0, #4
    bl      blink_n

    bl      clocks_init             @ clk_sys jumps to 150 MHz here
    movs    r0, #5
    bl      blink_n

    bl      tick_init
    movs    r0, #6
    bl      blink_n

    bl      watchdog_disable
    movs    r0, #7
    bl      blink_n

    bl      uart0_init
    movs    r0, #8
    bl      blink_n

    bl      clocks_post_pll_uart_baud_fixup
    movs    r0, #9
    bl      blink_n

.Lheartbeat:
    movs    r0, #10
    bl      blink_n
    b       .Lheartbeat

@ -----------------------------------------------------------------------------
@ diag_led_init - inline LED bring-up. Same MMIO sequence as gpio_led_init,
@ duplicated so a bug in gpio.S can't take down the diagnostic before stage 1.
@ -----------------------------------------------------------------------------
    .thumb_func
diag_led_init:
    @ PADS_BANK0[25] CLR = ISO|OD (0x180)
    movs    r1, #(0x180 >> 7)
    lsls    r1, #7
    ldr     r0, =PADS_BANK0_BASE + ATOMIC_CLR + 4 + (25 * PADS_BANK0_PAD_STRIDE)
    str     r1, [r0]

    @ IO_BANK0[25] CTRL = SIO (5)
    movs    r1, #GPIO_FUNC_SIO
    ldr     r0, =IO_BANK0_BASE + 4 + (25 * IO_BANK0_GPIO_CTRL_STRIDE)
    str     r1, [r0]

    @ SIO drive low + enable output on bit 25
    movs    r1, #1
    lsls    r1, #25
    ldr     r0, =SIO_BASE + SIO_GPIO_OUT_CLR
    str     r1, [r0]
    ldr     r0, =SIO_BASE + SIO_GPIO_OE_SET
    str     r1, [r0]
    bx      lr

@ -----------------------------------------------------------------------------
@ blink_n(r0=count) - flash LED `count` times, then pause.
@ Clobbers r0-r3.
@ -----------------------------------------------------------------------------
    .thumb_func
blink_n:
    push    {r4, r5, lr}
    mov     r4, r0                  @ r4 = remaining flashes
    movs    r5, #1
    lsls    r5, #25                 @ r5 = (1<<25), LED bit mask

.Lloop:
    cbz     r4, .Lpause

    @ LED on
    ldr     r0, =SIO_BASE + SIO_GPIO_OUT_SET
    str     r5, [r0]
    ldr     r0, =DELAY_ON
    bl      busy_delay

    @ LED off
    ldr     r0, =SIO_BASE + SIO_GPIO_OUT_CLR
    str     r5, [r0]
    ldr     r0, =DELAY_OFF
    bl      busy_delay

    subs    r4, #1
    b       .Lloop

.Lpause:
    ldr     r0, =DELAY_GAP
    bl      busy_delay
    pop     {r4, r5, pc}

@ -----------------------------------------------------------------------------
@ busy_delay(r0=cycles)
@ -----------------------------------------------------------------------------
    .thumb_func
busy_delay:
1:  subs    r0, #1
    bne     1b
    bx      lr
