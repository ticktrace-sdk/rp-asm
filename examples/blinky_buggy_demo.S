@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ blinky_buggy_demo.S - slot B app for the TSBL-ab rollback demo.
@
@ Intentionally broken: DOES NOT call boot_confirm() and arms a 3-second
@ watchdog that it never feeds. Visually obvious (fast ~10 Hz blink) so
@ you can see when the rollback kicks in.
@
@ Boot sequence on first cold boot of `firmware_rollback_demo.uf2`:
@   1. TSBL-ab picks slot B (higher seq=2 vs A's seq=1).
@   2. TSBL writes WATCHDOG_SCRATCH[6] = TRY_B and jumps here.
@   3. This app blinks fast for 3 seconds, arming a watchdog timer.
@   4. Watchdog times out -> warm reset (scratch survives).
@   5. TSBL sees scratch == TRY_B, infers slot B failed, rolls back to A.
@   6. Slot A's blinky_confirmed_demo runs, clears the scratch, blinks slow.
@
@ Pull USB and re-plug to repeat the cycle (POR clears scratch).
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ DELAY_10HZ,           2500000    @ ~50 ms half-period at 150 MHz
    .equ WATCHDOG_TIMEOUT_US,  3000000    @ 3 s

    .section .rodata.banner_buggy, "a"
banner_buggy:
    .asciz "ticktrace slot B (BUGGY, fast blink, no confirm) - will rollback in ~3s\r\n"

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      tick_init
    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup

    ldr     r0, =banner_buggy
    bl      uart0_puts

    @ Arm a 3-second watchdog. We never feed it, so it will fire and
    @ trigger a warm reset. The TSBL set WATCHDOG_SCRATCH[6] = TRY_B
    @ before jumping in here; we deliberately do NOT call boot_confirm,
    @ so the marker survives the warm reset and the TSBL rolls back.
    ldr     r0, =WATCHDOG_TIMEOUT_US
    bl      watchdog_enable

.Lloop:
    bl      gpio_led_toggle
    ldr     r0, =DELAY_10HZ
1:  subs    r0, #1
    bne     1b
    b       .Lloop
