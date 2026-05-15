@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ sha256_demo.S - hash "abc" via the hardware SHA-256 engine and print result
@
@ Expected digest for "abc":
@   ba7816bf 8f01cfea 414140de 5dae2223 b00361a3 396177a9 cb410ff6 1f20015a
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .section .rodata.demo, "a"
banner:
    .asciz "sha256: hashing \"abc\"\r\nresult: "
nl:
    .asciz "\r\n"
hex_digits:
    .ascii "0123456789abcdef"

msg_abc:
    .ascii "abc"
    .equ msg_abc_len, 3

    .section .bss.demo, "aw", %nobits
    .align 2
digest:
    .space 32

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

    bl      sha256_init

    ldr     r0, =banner
    bl      uart0_puts

    @ Compute SHA256("abc")
    ldr     r0, =msg_abc
    movs    r1, #msg_abc_len
    ldr     r2, =digest
    bl      sha256_compute

    @ Print 32 bytes of digest as hex
    ldr     r4, =digest
    movs    r5, #32
1:  ldrb    r0, [r4]
    bl      print_byte_hex
    adds    r4, #1
    subs    r5, #1
    bne     1b

    ldr     r0, =nl
    bl      uart0_puts

.Lloop:
    bl      gpio_led_toggle
    ldr     r0, =1500000
2:  subs    r0, #1
    bne     2b
    b       .Lloop

@ -----------------------------------------------------------------------------
@ print_byte_hex(r0 = byte) - emits two hex chars on UART0
@ -----------------------------------------------------------------------------
    .thumb_func
print_byte_hex:
    push    {r4, r5, lr}
    mov     r4, r0
    ldr     r5, =hex_digits
    lsrs    r0, r4, #4
    and     r0, #0xF
    ldrb    r0, [r5, r0]
    movs    r1, r0
    movs    r0, #0          @ uart idx
    bl      uart_putc_blocking
    and     r0, r4, #0xF
    ldrb    r0, [r5, r0]
    movs    r1, r0
    movs    r0, #0
    bl      uart_putc_blocking
    pop     {r4, r5, pc}
