@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ trng_demo.S - print 8 random 32-bit words from the hardware TRNG
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .section .rodata.demo, "a"
banner:
    .asciz "trng demo:\r\n"
prefix:
    .asciz "rnd="
nl:
    .asciz "\r\n"
hex_digits:
    .ascii "0123456789abcdef"

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup

    bl      trng_init

    ldr     r0, =banner
    bl      uart0_puts

    movs    r4, #8
1:  bl      trng_get_random_word
    push    {r0, r4}
    ldr     r0, =prefix
    bl      uart0_puts
    pop     {r0, r4}
    bl      print_u32_hex
    ldr     r0, =nl
    bl      uart0_puts
    subs    r4, #1
    bne     1b

.Lloop:
    bl      gpio_led_toggle
    ldr     r0, =12500000
2:  subs    r0, #1
    bne     2b
    b       .Lloop

    .thumb_func
print_u32_hex:
    push    {r4, r5, r6, lr}
    mov     r4, r0
    ldr     r5, =hex_digits
    movs    r6, #28
1:  mov     r0, r4
    lsrs    r0, r6
    and     r0, #0xF
    ldrb    r0, [r5, r0]
    movs    r1, r0
    movs    r0, #0
    bl      uart_putc_blocking
    subs    r6, #4
    bge     1b
    pop     {r4, r5, r6, pc}
