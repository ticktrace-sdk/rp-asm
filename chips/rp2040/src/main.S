@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ main.S - M2 firmware for RP2040: 125 MHz clock-tree bring-up + UART banner
@ + blinky.
@
@ Boot path (post-bootrom -> _reset -> main):
@   1. xosc_init                       XOSC stable @ 12 MHz
@   2. pll_sys_125_mhz                 pll_sys @ 125 MHz
@   3. pll_usb_48_mhz                  pll_usb @  48 MHz
@   4. clocks_init                     clk_ref = xosc, clk_sys = pll_sys,
@                                      clk_peri = clk_sys, clk_usb = pll_usb,
@                                      clk_adc = pll_usb
@   5. tick_init                       WATCHDOG.TICK = 1 MHz (12 cycles of clk_ref)
@   6. watchdog_disable                explicit safe state
@   7. gpio_led_init / uart0_init      reuse drivers (GP25 LED, GP0/GP1 UART)
@   8. clocks_post_pll_uart_baud_fixup re-tune IBRD/FBRD for 125 MHz clk_peri
@   9. uart0_puts(banner)              "ticktrace M2 RP2040 - clk_sys = 125 MHz\r\n"
@  10. forever: toggle LED + busy-loop ~250 ms
@
@ Cycle math for the busy loop:
@   3-cycle inner body (subs + bne) at 125 MHz = 24 ns / iteration.
@   DELAY_COUNT = 10_416_666 -> ~250 ms half-period -> ~2 Hz blink.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m0plus
    .thumb

    .equ DELAY_COUNT_125MHZ, 10416666

    .section .rodata.banner, "a"
banner:
    .asciz "ticktrace M2 RP2040 - clk_sys = 125 MHz\r\n"

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    @ ---- Clock tree bring-up ----------------------------------------------
    bl      xosc_init
    bl      pll_sys_125_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      tick_init
    bl      watchdog_disable

    @ ---- Peripheral init at the new clock rate ----------------------------
    bl      gpio_led_init
    bl      uart0_init                      @ wrong baud (computed for 12 MHz)
    bl      clocks_post_pll_uart_baud_fixup @ fix to 125 MHz divisors

    ldr     r0, =banner
    bl      uart0_puts

.Lloop:
    bl      gpio_led_toggle

    ldr     r0, =DELAY_COUNT_125MHZ
1:  subs    r0, #1
    bne     1b

    b       .Lloop
