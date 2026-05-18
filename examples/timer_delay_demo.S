@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/timer_delay_demo.S - blink the LED using delay_us / delay_ms.
@
@ Boots through the M2 path (clk_sys = 150 MHz, 1 MHz tick into TIMER0/1),
@ takes the timer block out of reset, prints a banner, and then blinks the
@ on-board LED at 2 Hz using TIMER0-driven busy waits.
@
@ Build:    make build/timer_delay_demo.uf2
@
@ The TIMER source files are .include'd directly so the existing Makefile
@ DRIVER_SRC list does not need to be edited (M3-B conflict-avoidance rule).
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .section .rodata.banner_timer, "a"
banner_timer:
    .asciz "ticktrace M3-B - delay_us blink\r\n"

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    @ ---- Clock tree bring-up (reuse M2 path) ------------------------------
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      tick_init                       @ 1 MHz tick into TIMER0/1
    bl      watchdog_disable

    @ ---- M3-B: bring TIMER0/1 out of reset --------------------------------
    bl      timer_init

    @ ---- Peripheral init at the new clock rate ----------------------------
    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup

    ldr     r0, =banner_timer
    bl      uart0_puts

.Lloop:
    bl      gpio_led_toggle
    movs    r0, #250                        @ 250 ms
    bl      delay_ms
    b       .Lloop

@ ---- Bundle the M3-B driver objects into this image -----------------------
    .include "src/timer.S"
