@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/clocks_demo.S - end-to-end M2 clock-tree bring-up demo.
@
@ Boots the chip with the v0.1 startup, brings clk_sys up to 150 MHz from
@ the 12 MHz crystal, fixes up the UART baud divisors for the new clock
@ rate, and then prints a banner + blinks the LED at ~1 Hz.
@
@ Build:    make examples/clocks_demo.uf2  ->  build/clocks_demo.uf2
@ Flash:    drop build/clocks_demo.uf2 onto the BOOTSEL drive
@ Verify:   115200 8N1 on GP0; the banner should read
@             ticktrace M2 - clk_sys = 150 MHz
@           and the LED should toggle every ~1 second.
@
@ With clk_sys = 150 MHz the inner busy-loop runs ~12.5x faster than v0.1,
@ so the delay constant has to grow accordingly:
@   v0.1 (12 MHz):  DELAY_COUNT = 1_000_000  -> ~250 ms half period
@   M2 (150 MHz):   DELAY_COUNT = 12_500_000 -> ~250 ms half period
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ DELAY_COUNT_150MHZ, 12500000

    .section .rodata.banner, "a"
banner:
    .asciz "ticktrace M2 - clk_sys = 150 MHz\r\n"

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    @ ---- Clock tree bring-up ---------------------------------------------
    bl      xosc_init                       @ XOSC stable
    bl      pll_sys_150_mhz                 @ pll_sys = 150 MHz
    bl      pll_usb_48_mhz                  @ pll_usb = 48 MHz
    bl      clocks_init                     @ wire muxes
    bl      tick_init                       @ 1 MHz tick to TIMER0/1/WDG
    bl      watchdog_disable                @ explicit safe state

    @ ---- Peripheral init at the new clock rate ---------------------------
    bl      gpio_led_init                   @ LED on GP25
    bl      uart0_init                      @ wrong baud (computed for 12 MHz)
    bl      clocks_post_pll_uart_baud_fixup @ fix to 150 MHz divisors

    ldr     r0, =banner
    bl      uart0_puts

.Lloop:
    bl      gpio_led_toggle

    ldr     r0, =DELAY_COUNT_150MHZ
1:  subs    r0, #1
    bne     1b

    b       .Lloop
