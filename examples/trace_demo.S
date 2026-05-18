@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ trace_demo.S - CoreSight bring-up + ITM printf + DWT cycle measurement
@
@ Verify on Pico 2 with a SWD probe:
@   1. Connect SWCLK/SWDIO + GND from probe to the debug header.
@   2. SWO needs to be routed to a GPIO and wired to the probe's SWO/RX
@      input (or a USB UART).  Default route below assumes the openocd
@      config has selected the appropriate GPIO funcsel for SWO.
@   3. With openocd + tpiu config (see docs/trace.md), `printf` output
@      arrives on a TCP port and DWT cycle counts can be sampled.
@
@ Also prints the measured cycle count over UART0 so you can sanity-check
@ without any debug probe at all.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ CLK_SYS_HZ,    150000000
    .equ SWO_BAUD,      2000000              @ 2 Mbps - clean integer divisor

    .section .rodata.demo, "a"
banner:
    .asciz "trace demo - clk_sys=150 MHz\r\n"
itm_msg:
    .asciz "hello via ITM port 0\n"
cycles_pre:
    .asciz "1000 iters took "
cycles_post:
    .asciz " cycles\r\n"
hex_digits:
    .ascii "0123456789abcdef"

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    @ Standard clock + UART bring-up
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup

    @ Trace block bring-up
    ldr     r0, =CLK_SYS_HZ
    ldr     r1, =SWO_BAUD
    bl      trace_init

    @ Banner on UART
    ldr     r0, =banner
    bl      uart0_puts

    @ Hello via ITM port 0 (visible on openocd tpiu output)
    movs    r0, #0
    ldr     r1, =itm_msg
    bl      itm_puts

    @ ---- Measure a known workload with DWT --------------------------------
    bl      dwt_cycles_read              @ r0 = t_start
    mov     r4, r0
    @ Workload: 1000 iterations of a subs/bne loop.
    @ Inner body 'subs r0, #1; bne 1b' is 1 + 2 cycles taken (M33: subs=1,
    @ taken branch=2) => 3 cycles per iter, 3000 cycles total (+ ~5 over).
    movs    r0, #250
    movs    r1, #4
    muls    r0, r0, r1                   @ r0 = 1000
1:  subs    r0, #1
    bne     1b

    mov     r0, r4
    bl      dwt_cycles_since             @ r0 = delta

    @ Print "1000 iters took NNNNNNNN cycles" via UART
    mov     r4, r0
    ldr     r0, =cycles_pre
    bl      uart0_puts
    mov     r0, r4
    bl      print_u32_hex
    ldr     r0, =cycles_post
    bl      uart0_puts

    @ Also emit the cycle count via ITM as a single 32-bit packet on port 1
    movs    r0, #1
    mov     r1, r4
    bl      itm_putw

.Lloop:
    bl      gpio_led_toggle
    ldr     r0, =12500000
2:  subs    r0, #1
    bne     2b
    b       .Lloop

@ -----------------------------------------------------------------------------
@ print_u32_hex(r0=value) - 8 hex digits via UART0
@ -----------------------------------------------------------------------------
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
