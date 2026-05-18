@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ main.S - M2 firmware: 150 MHz clock-tree bring-up + UART banner + blinky.
@
@ Boot path (post-bootrom -> _reset -> main):
@   1. xosc_init                      -> XOSC stable @ 12 MHz
@   2. pll_sys_150_mhz                -> pll_sys @ 150 MHz
@   3. pll_usb_48_mhz                 -> pll_usb @  48 MHz
@   4. clocks_init                    -> clk_sys = clk_peri = 150 MHz,
@                                        clk_usb = clk_adc = 48 MHz
@   5. tick_init                      -> TIMER0/1/WATCHDOG ticks @ 1 MHz
@   6. watchdog_disable               -> explicit safe state
@   7. gpio_led_init / uart0_init     -> reuse v0.1 drivers
@   8. clocks_post_pll_uart_baud_fixup-> retune IBRD/FBRD for 150 MHz
@   9. uart0_puts(banner)             -> "ticktrace M2 - clk_sys = 150 MHz\r\n"
@  10. forever: toggle LED + busy-loop ~250 ms
@
@ Cycle math for the busy loop:
@   3-cycle inner body (subs + bne) at 150 MHz = 20 ns / iteration.
@   DELAY_COUNT = 12_500_000 -> 250 ms half-period -> ~2 Hz blink.
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
