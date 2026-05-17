@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/blinky_v01.S - the v0.1 demo, preserved for regression testing.
@
@ Same exact sequence as the original src/main.S in v0.1: post-bootrom we
@ have clk_sys = 12 MHz from XOSC pass-through, init UART (with 12 MHz
@ baud divisors) and the LED, then loop printing "tick\r\n" while toggling
@ the LED.
@
@ Useful for:
@   - exercising the v0.1 MMIO write trace under T1 (tests/unicorn/test_v01_blinky.py)
@   - confirming the existing 12 MHz UART driver still works without M2's
@     clock-tree bring-up
@
@ NOT FOR REAL HARDWARE: on a flash-booted board this image hangs in
@ uart0_init because UART0's RESET_DONE never asserts without clk_peri
@ being brought up by clocks_init (see src/uart.S near "RESET_DONE
@ won't assert there because clk_peri isn't running yet").  The hang
@ happens before the LED toggle loop, so the LED does not blink.
@ Test on hardware with blinky.uf2 (src/main.S) instead.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ DELAY_COUNT, 1000000

    .section .rodata.banner_v01, "a"
banner:
    .asciz "rp-asm v0.1 - every cycle matters\r\n"
tick_msg:
    .asciz "tick\r\n"

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    bl      gpio_led_init
    bl      uart0_init

    ldr     r0, =banner
    bl      uart0_puts

.Lloop:
    bl      gpio_led_toggle

    ldr     r0, =tick_msg
    bl      uart0_puts

    ldr     r0, =DELAY_COUNT
1:  subs    r0, #1
    bne     1b

    b       .Lloop
