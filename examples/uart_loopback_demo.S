@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/uart_loopback_demo.S - UART0 <-> UART1 cross-loopback (M4-E).
@
@ Hardware wiring required (the user must jumper this on the carrier):
@   GP0 (UART0 TX)  --to--  GP5 (UART1 RX)
@   GP4 (UART1 TX)  --to--  GP1 (UART0 RX)
@
@ Both UARTs run at 921600 8N1 to stress the FIFO + baud math (this is the
@ slot where divisor errors usually first show up because IBRD < 16).
@
@ Test:
@   1. Send "ping" from UART0; expect to read "ping" back from UART1.
@   2. Send "pong" from UART1; expect to read "pong" back from UART0.
@   3. Print the result on UART0 via the blocking driver.
@   4. Toggle GP25 LED on success forever; freeze it on failure.
@ =============================================================================

    .include "rp2350.inc"
    .include "uart.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ LED_PIN, 25
    .equ TEST_BAUD, 921600

    .section .rodata.uart_loop_strings, "a"
ping_str:
    .ascii "ping"
ping_end:
pong_str:
    .ascii "pong"
pong_end:
banner_ok:
    .asciz "uart-loopback OK\r\n"
banner_fail:
    .asciz "uart-loopback FAIL\r\n"

@ ----------------------------------------------------------------------------
@ Helper: send 4 bytes from r0=base_str to UART idx in r1.
@   Clobbers r0..r4.
@ ----------------------------------------------------------------------------
    .section .text.send4, "ax"
    .thumb_func
send4:
    push    {r4, r5, r6, lr}
    mov     r4, r0                          @ str ptr
    mov     r5, r1                          @ idx
    movs    r6, #4
1:  ldrb    r1, [r4], #1
    mov     r0, r5
    bl      uart_putc_blocking
    subs    r6, #1
    bne     1b
    pop     {r4, r5, r6, pc}

@ ----------------------------------------------------------------------------
@ Helper: read 4 bytes from UART idx in r0 into buffer at r1.
@   Returns r0 = 0 on OK.  Clobbers r0..r5.
@ ----------------------------------------------------------------------------
    .section .text.recv4, "ax"
    .thumb_func
recv4:
    push    {r4, r5, r6, lr}
    mov     r5, r0                          @ idx
    mov     r4, r1                          @ buf
    movs    r6, #4
1:  mov     r0, r5
    bl      uart_getc_blocking
    strb    r0, [r4], #1
    subs    r6, #1
    bne     1b
    movs    r0, #0
    pop     {r4, r5, r6, pc}

@ ----------------------------------------------------------------------------
@ Helper: memcmp4(a, b) -> r0 = 0 if equal
@ ----------------------------------------------------------------------------
    .section .text.memcmp4, "ax"
    .thumb_func
memcmp4:
    movs    r2, #4
1:  ldrb    r3, [r0], #1
    ldrb    r12, [r1], #1
    cmp     r3, r12
    bne     2f
    subs    r2, #1
    bne     1b
    movs    r0, #0
    bx      lr
2:  movs    r0, #1
    bx      lr

    .section .bss.uart_loop_buf, "aw"
    .align 2
rx_buf0:
    .space 8
rx_buf1:
    .space 8

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    push    {r4, lr}

    @ ---- Clock tree bring-up --------------------------------------------
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      tick_init
    bl      watchdog_disable

    @ ---- LED on GP25 as output ------------------------------------------
    movs    r0, #LED_PIN
    bl      gpio_init
    movs    r0, #LED_PIN
    movs    r1, #1
    bl      gpio_set_dir

    @ ---- Both UARTs at 921600 8N1 ---------------------------------------
    movs    r0, #0
    ldr     r1, =TEST_BAUD
    ldr     r2, =150000000
    bl      uart_init
    movs    r0, #1
    ldr     r1, =TEST_BAUD
    ldr     r2, =150000000
    bl      uart_init

    @ ---- Test 1: UART0 -> UART1 ("ping") --------------------------------
    ldr     r0, =ping_str
    movs    r1, #0
    bl      send4
    movs    r0, #1
    ldr     r1, =rx_buf1
    bl      recv4
    ldr     r0, =rx_buf1
    ldr     r1, =ping_str
    bl      memcmp4
    cbnz    r0, .Lfail

    @ ---- Test 2: UART1 -> UART0 ("pong") --------------------------------
    ldr     r0, =pong_str
    movs    r1, #1
    bl      send4
    movs    r0, #0
    ldr     r1, =rx_buf0
    bl      recv4
    ldr     r0, =rx_buf0
    ldr     r1, =pong_str
    bl      memcmp4
    cbnz    r0, .Lfail

    @ ---- Pass: banner + LED toggle loop ---------------------------------
    movs    r0, #0
    ldr     r1, =banner_ok
    bl      uart_puts_blocking
.Lpass_loop:
    movs    r0, #LED_PIN
    bl      gpio_toggle
    ldr     r0, =5000000
1:  subs    r0, #1
    bne     1b
    b       .Lpass_loop

.Lfail:
    movs    r0, #0
    ldr     r1, =banner_fail
    bl      uart_puts_blocking
.Lfail_loop:
    wfi
    b       .Lfail_loop
